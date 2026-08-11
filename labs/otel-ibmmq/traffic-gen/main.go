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
	ep string // bsi.ep — entry point
	ch string // bsi.ch — channel
	cj string // bsi.cj — customer journey
}

// Happy-path entries get 5 slots each; DLQ entries get 1-2 slots (~17% error rate).
var pool = []msg{
	{ep: "checkout", ch: "android", cj: "MoneyTransfer"},
	{ep: "checkout", ch: "android", cj: "MoneyTransfer"},
	{ep: "checkout", ch: "ios", cj: "MoneyTransfer"},
	{ep: "checkout", ch: "web", cj: "AccountOpen"},
	{ep: "checkout", ch: "web", cj: "AccountOpen"},
	{ep: "payment", ch: "android", cj: "CardActivation"},
	{ep: "payment", ch: "ios", cj: "CardActivation"},
	{ep: "payment", ch: "web", cj: "MoneyTransfer"},
	{ep: "payment", ch: "android", cj: "MoneyTransfer"},
	{ep: "payment", ch: "ios", cj: "AccountOpen"},
	{ep: "account", ch: "web", cj: "CardActivation"},
	{ep: "account", ch: "android", cj: "AccountOpen"},
	{ep: "account", ch: "ios", cj: "CardActivation"},
	{ep: "account", ch: "web", cj: "MoneyTransfer"},
	{ep: "account", ch: "ios", cj: "AccountOpen"},
	{ep: "blocked", ch: "android", cj: "MoneyTransfer"},  // → DLQ
	{ep: "bad-tenant", ch: "web", cj: "AccountOpen"},     // → DLQ
	{ep: "blocked", ch: "ios", cj: "CardActivation"},     // → DLQ
}

func main() {
	url := flag.String("url", "http://localhost:8080/send", "gateway /send endpoint")
	rate := flag.Duration("interval", 1*time.Second, "delay between requests")
	flag.Parse()

	log.Printf("traffic-gen → %s  (interval=%s)", *url, *rate)
	log.Printf("entry-points: %s", uniqueEps())

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
				log.Printf("FAIL ep=%-12s ch=%-8s cj=%s  err=%v", m.ep, m.ch, m.cj, err)
			} else {
				ok++
				log.Printf("OK   ep=%-12s ch=%-8s cj=%s", m.ep, m.ch, m.cj)
			}
		}
	}
}

func post(client *http.Client, url string, m msg) error {
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(""))
	if err != nil {
		return err
	}
	req.Header.Set("X-bsi-ep", m.ep)
	req.Header.Set("X-bsi-ch", m.ch)
	req.Header.Set("X-bsi-cj", m.cj)

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

func uniqueEps() string {
	seen := map[string]bool{}
	var out []string
	for _, m := range pool {
		if !seen[m.ep] {
			seen[m.ep] = true
			out = append(out, m.ep)
		}
	}
	return strings.Join(out, ", ")
}
