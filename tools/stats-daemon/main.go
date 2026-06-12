// vortex-stats — tiny localhost API behind Caddy.
//
//	GET /stats            live system stats for the landing page (poll every 5s)
//	GET /setup/           first-boot wizard (until /etc/vortex/.initialized exists)
//	POST /setup/api/submit  hands the wizard payload to the root-side applier
//
// Runs unprivileged (DynamicUser). Privileged setup actions are performed by
// vortex-setup-apply.service (root), which watches /run/vortex-setup/request.json
// via a systemd path unit. This process never holds root and never logs secrets.
package main

import (
	"crypto/subtle"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

//go:embed setup.html
var setupHTML []byte

const (
	listenAddr      = "127.0.0.1:8090"
	initializedFile = "/etc/vortex/.initialized"
	runDir          = "/run/vortex-setup"
	codeFile        = runDir + "/code"
	requestFile     = runDir + "/request.json"
	resultFile      = runDir + "/result.json"
	applyTimeout    = 240 * time.Second
)

// ---------------------------------------------------------------- /stats ---

type memStats struct {
	TotalMB     int64 `json:"total_mb"`
	UsedMB      int64 `json:"used_mb"`
	AvailableMB int64 `json:"available_mb"`
	SwapTotalMB int64 `json:"swap_total_mb"`
	SwapUsedMB  int64 `json:"swap_used_mb"`
}

type zramStats struct {
	Active   bool    `json:"active"`
	OrigMB   float64 `json:"orig_mb"`
	ComprMB  float64 `json:"compr_mb"`
	Ratio    float64 `json:"ratio"`
}

type statsResponse struct {
	Hostname    string          `json:"hostname"`
	Version     string          `json:"version"`
	UptimeSec   int64           `json:"uptime_sec"`
	Load1       float64         `json:"load1"`
	Mem         memStats        `json:"mem"`
	Zram        zramStats       `json:"zram"`
	TempC       *float64        `json:"temp_c"` // null when no sensor (VMs)
	Openclaw    string          `json:"openclaw"`
	Profile     json.RawMessage `json:"profile"`
	Initialized bool            `json:"initialized"`
}

func meminfo() (memStats, error) {
	b, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return memStats{}, err
	}
	v := map[string]int64{}
	for _, ln := range strings.Split(string(b), "\n") {
		f := strings.Fields(ln)
		if len(f) >= 2 {
			n, _ := strconv.ParseInt(f[1], 10, 64)
			v[strings.TrimSuffix(f[0], ":")] = n / 1024 // kB → MB
		}
	}
	return memStats{
		TotalMB:     v["MemTotal"],
		UsedMB:      v["MemTotal"] - v["MemAvailable"],
		AvailableMB: v["MemAvailable"],
		SwapTotalMB: v["SwapTotal"],
		SwapUsedMB:  v["SwapTotal"] - v["SwapFree"],
	}, nil
}

func zram() zramStats {
	b, err := os.ReadFile("/sys/block/zram0/mm_stat")
	if err != nil {
		return zramStats{}
	}
	f := strings.Fields(string(b))
	if len(f) < 2 {
		return zramStats{}
	}
	orig, _ := strconv.ParseFloat(f[0], 64)
	compr, _ := strconv.ParseFloat(f[1], 64)
	z := zramStats{Active: true, OrigMB: orig / 1048576, ComprMB: compr / 1048576}
	if compr > 0 {
		z.Ratio = orig / compr
	}
	return z
}

func cpuTemp() *float64 {
	zones, _ := filepath.Glob("/sys/class/thermal/thermal_zone*/temp")
	for _, z := range zones {
		b, err := os.ReadFile(z)
		if err != nil {
			continue
		}
		n, err := strconv.ParseFloat(strings.TrimSpace(string(b)), 64)
		if err == nil && n > 0 {
			c := n / 1000
			return &c
		}
	}
	return nil
}

func uptimeSec() int64 {
	b, _ := os.ReadFile("/proc/uptime")
	f := strings.Fields(string(b))
	if len(f) > 0 {
		s, _ := strconv.ParseFloat(f[0], 64)
		return int64(s)
	}
	return 0
}

func load1() float64 {
	b, _ := os.ReadFile("/proc/loadavg")
	f := strings.Fields(string(b))
	if len(f) > 0 {
		l, _ := strconv.ParseFloat(f[0], 64)
		return l
	}
	return 0
}

func unitState(unit string) string {
	out, _ := exec.Command("systemctl", "is-active", unit).Output()
	s := strings.TrimSpace(string(out))
	if s == "" {
		s = "unknown"
	}
	return s
}

func tuneProfile() json.RawMessage {
	out, err := exec.Command("/usr/sbin/vortex-tune", "--json").Output()
	if err != nil {
		return json.RawMessage(`null`)
	}
	return json.RawMessage(strings.TrimSpace(string(out)))
}

func vortexVersion() string {
	b, err := os.ReadFile("/etc/vortex-release")
	if err != nil {
		return "unknown"
	}
	for _, ln := range strings.Split(string(b), "\n") {
		if v, ok := strings.CutPrefix(ln, "VORTEX_VERSION="); ok {
			return v
		}
	}
	return "unknown"
}

func initialized() bool {
	_, err := os.Stat(initializedFile)
	return err == nil
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	mem, _ := meminfo()
	host, _ := os.Hostname()
	resp := statsResponse{
		Hostname:    host,
		Version:     vortexVersion(),
		UptimeSec:   uptimeSec(),
		Load1:       load1(),
		Mem:         mem,
		Zram:        zram(),
		TempC:       cpuTemp(),
		Openclaw:    unitState("openclaw.service"),
		Profile:     tuneProfile(),
		Initialized: initialized(),
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(resp)
}

// ---------------------------------------------------------------- /setup ---

type setupRequest struct {
	Code         string            `json:"code"`
	Password     string            `json:"password"`
	SSHKey       string            `json:"ssh_key"`
	APIKeys      map[string]string `json:"api_keys"`
	Timezone     string            `json:"timezone"`
	TailscaleKey string            `json:"tailscale_key"`
}

func codeOK(supplied string) bool {
	want, err := os.ReadFile(codeFile)
	if err != nil {
		return false
	}
	w := strings.TrimSpace(string(want))
	return len(w) > 0 &&
		subtle.ConstantTimeCompare([]byte(w), []byte(strings.TrimSpace(supplied))) == 1
}

func handleSetupPage(w http.ResponseWriter, r *http.Request) {
	if initialized() {
		http.Error(w, "This machine is already set up.", http.StatusGone)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(setupHTML)
}

func handleSetupSubmit(w http.ResponseWriter, r *http.Request) {
	if initialized() {
		http.Error(w, `{"error":"already initialized"}`, http.StatusGone)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, `{"error":"POST only"}`, http.StatusMethodNotAllowed)
		return
	}
	var req setupRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&req); err != nil {
		http.Error(w, `{"error":"bad json"}`, http.StatusBadRequest)
		return
	}
	if !codeOK(req.Code) {
		time.Sleep(2 * time.Second) // slow brute force
		http.Error(w, `{"error":"wrong setup code"}`, http.StatusForbidden)
		return
	}
	if len(req.Password) < 8 {
		http.Error(w, `{"error":"password must be at least 8 characters"}`, http.StatusBadRequest)
		return
	}

	os.Remove(resultFile)
	payload, _ := json.Marshal(req)
	if err := os.WriteFile(requestFile, payload, 0o660); err != nil {
		log.Printf("setup: cannot write request: %v", err) // no secrets in this line
		http.Error(w, `{"error":"cannot hand off to applier"}`, http.StatusInternalServerError)
		return
	}

	// The root-side path unit picks up request.json; wait for its verdict.
	deadline := time.Now().Add(applyTimeout)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(resultFile); err == nil {
			os.Remove(resultFile)
			w.Header().Set("Content-Type", "application/json")
			w.Write(b)
			return
		}
		time.Sleep(1 * time.Second)
	}
	http.Error(w, `{"error":"setup timed out — check journalctl -u vortex-setup-apply"}`, http.StatusGatewayTimeout)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/stats", handleStats)
	mux.HandleFunc("/api/stats", handleStats) // same path Caddy proxies verbatim
	mux.HandleFunc("/setup", handleSetupPage)
	mux.HandleFunc("/setup/", handleSetupPage)
	mux.HandleFunc("/setup/api/submit", handleSetupSubmit)

	srv := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: applyTimeout + 30*time.Second,
	}
	log.Printf("vortex-stats listening on %s", listenAddr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
