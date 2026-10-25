// pp-agent is the on-tablet update agent. One command per run; systemd
// timers and boot units call it. See agent/README.md.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"paper-pure/agent/internal/agent"
)

const usage = `usage: pp-agent [-config FILE] COMMAND

  update       check the feed, install a new signed release, health-check,
               roll back by itself on failure, report (the timer runs this)
  boot         once per boot: finish an interrupted install, apply the
               boot-loop guard, activate the current release, report
  status       print state as JSON
  rollback     reinstall the previous release (manual undo)
  reset-guard  clear the boot-loop guard
  report       send status to the server now
  version      print the agent version
`

func main() {
	cfgPath := flag.String("config", "/home/root/paper-pure/agent.json", "config file")
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()
	if flag.NArg() != 1 {
		flag.Usage()
		os.Exit(2)
	}
	cmd := flag.Arg(0)
	if cmd == "version" {
		fmt.Println(agent.Version)
		return
	}
	cfg, err := agent.LoadConfig(*cfgPath)
	if err != nil {
		fatal(err)
	}
	a, err := agent.New(cfg)
	if err != nil {
		fatal(err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	switch cmd {
	case "update":
		err = a.Update(ctx)
		if errors.Is(err, agent.ErrBusy) {
			fmt.Fprintln(os.Stderr, "pp-agent: busy, another run holds the lock")
			return
		}
	case "boot":
		err = a.Boot(ctx)
	case "rollback":
		err = a.Rollback(ctx)
	case "reset-guard":
		err = a.ResetGuard(ctx)
	case "report":
		err = a.Report(ctx)
	case "status":
		var s agent.Status
		s, err = a.Status()
		if err == nil {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			enc.Encode(s)
		}
	default:
		flag.Usage()
		os.Exit(2)
	}
	if err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "pp-agent:", err)
	os.Exit(1)
}
