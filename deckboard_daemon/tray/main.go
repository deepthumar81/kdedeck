package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/getlantern/systray"
)

const dashboardURL = "http://127.0.0.1:8484/?tray=1"

var backendCmd *exec.Cmd

var (
	commandRunner = exec.Command
	openURL       = openBrowser
)

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetTitle("Deckboard")
	systray.SetTooltip("Deckboard Daemon")

	mOpen := systray.AddMenuItem("Open Dashboard", "Open the configurator in your browser")
	mPair := systray.AddMenuItem("Pair a Device", "Open the pairing panel with a one-time code")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop the server and quit")

	go startBackendAndOpen()
	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				_ = openURL(dashboardURL)
			case <-mPair.ClickedCh:
				_ = openURL(dashboardURL + "#pairing")
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {
	if backendCmd != nil && backendCmd.Process != nil {
		_ = backendCmd.Process.Kill()
	}
}

func startBackendAndOpen() {
	if err := startBackend(); err != nil {
		fmt.Fprintf(os.Stderr, "Deckboard daemon could not start: %v\n", err)
		return
	}
	if err := waitForReady(10 * time.Second); err != nil {
		fmt.Fprintf(os.Stderr, "Deckboard daemon is not ready: %v\n", err)
		// Keep a still-running secure/LAN daemon alive: its endpoint may not be
		// reachable through the loopback HTTP probe, but Quit can still own it.
		if backendCmd != nil && backendCmd.Process != nil && backendCmd.ProcessState != nil {
			_ = backendCmd.Process.Kill()
		}
		return
	}
	if err := openURL(dashboardURL); err != nil {
		fmt.Fprintf(os.Stderr, "Could not open the Deckboard dashboard: %v\n", err)
	}
}

func startBackend() error {
	root, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating tray executable: %w", err)
	}
	trayDir := filepath.Dir(root)
	backendDir := filepath.Clean(filepath.Join(trayDir, "..", "backend"))
	// `go run` places the temporary executable outside the checkout. Keep
	// development runs portable while installed tray builds remain relative
	// to their own executable.
	if _, statErr := os.Stat(backendDir); statErr != nil {
		if workingDir, workingErr := os.Getwd(); workingErr == nil {
			for _, candidate := range []string{
				filepath.Join(workingDir, "backend"),
				filepath.Join(workingDir, "..", "backend"),
			} {
				if _, candidateErr := os.Stat(candidate); candidateErr == nil {
					backendDir = filepath.Clean(candidate)
					break
				}
			}
		}
	}
	binaryPath := filepath.Join(backendDir, "kdedeck_daemon")
	var cmd *exec.Cmd
	if _, statErr := os.Stat(binaryPath); statErr == nil {
		cmd = commandRunner(binaryPath, "--tray")
	} else {
		cmd = commandRunner("dart", "run", "bin/backend.dart", "--tray")
	}
	cmd.Dir = backendDir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return err
	}
	backendCmd = cmd
	go func() { _ = cmd.Wait() }()
	return nil
}

func waitForReady(timeout time.Duration) error {
	return waitForReadyURL("http://127.0.0.1:8484/healthz", timeout)
}

func waitForReadyURL(endpoint string, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return err
	}
	client := &http.Client{Timeout: 750 * time.Millisecond}
	for {
		response, requestErr := client.Do(request.Clone(ctx))
		if requestErr == nil {
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("readiness check timed out")
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func openBrowser(url string) error {
	switch runtime.GOOS {
	case "linux":
		return exec.Command("xdg-open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		return exec.Command("open", url).Start()
	default:
		return fmt.Errorf("unsupported platform")
	}
}
