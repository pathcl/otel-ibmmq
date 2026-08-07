package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

type msg struct {
	tenantID string
	userID   string
}

// Happy-path tenants get 5 slots each; DLQ tenants get 1 slot each (~17% error rate).
var pool = []msg{
	{tenantID: "acme", userID: "alice"},
	{tenantID: "acme", userID: "bob"},
	{tenantID: "acme", userID: "carol"},
	{tenantID: "acme", userID: "alice"},
	{tenantID: "acme", userID: "bob"},
	{tenantID: "globex", userID: "dave"},
	{tenantID: "globex", userID: "eve"},
	{tenantID: "globex", userID: "dave"},
	{tenantID: "globex", userID: "eve"},
	{tenantID: "globex", userID: "frank"},
	{tenantID: "initech", userID: "grace"},
	{tenantID: "initech", userID: "hank"},
	{tenantID: "initech", userID: "grace"},
	{tenantID: "initech", userID: "hank"},
	{tenantID: "initech", userID: "iris"},
	{tenantID: "bad-tenant", userID: "mallory"}, // → DLQ
	{tenantID: "blocked", userID: "trudy"},       // → DLQ
	{tenantID: "blocked", userID: "trudy"},
}

func main() {
	url := flag.String("url", "http://localhost:8080/send", "gateway /send endpoint")
	rate := flag.Duration("interval", 1*time.Second, "delay between requests")
	flag.Parse()

	log.Printf("traffic-gen → %s  (interval=%s)", *url, *rate)
	log.Printf("tenants: %s", uniqueTenants())

	client := &http.Client{Timeout: 5 * time.Second}
	ticker := time.NewTicker(*rate)
	defer ticker.Stop()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	var ok, errs int
	for {
		select {
		case <-quit:
			log.Printf("stopped — sent=%d err=%d", ok, errs)
			return
		case <-ticker.C:
			m := pool[rand.Intn(len(pool))]
			err := post(client, *url, m)
			if err != nil {
				errs++
				log.Printf("FAIL tenant=%-12s user=%-8s err=%v", m.tenantID, m.userID, err)
			} else {
				ok++
				log.Printf("OK   tenant=%-12s user=%s", m.tenantID, m.userID)
			}
		}
	}
}

func post(client *http.Client, url string, m msg) error {
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(""))
	if err != nil {
		return err
	}
	req.Header.Set("X-Tenant-ID", m.tenantID)
	req.Header.Set("X-User-ID", m.userID)

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func uniqueTenants() string {
	seen := map[string]bool{}
	var out []string
	for _, m := range pool {
		if !seen[m.tenantID] {
			seen[m.tenantID] = true
			out = append(out, m.tenantID)
		}
	}
	return strings.Join(out, ", ")
}
