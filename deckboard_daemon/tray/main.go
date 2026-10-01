package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"github.com/getlantern/systray"
)

var backendCmd *exec.Cmd

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetTitle("Deckboard")
	systray.SetTooltip("Deckboard Daemon is running")
	// systray.SetIcon(iconData) // Using text title for simplicity if no icon provided

	mOpen := systray.AddMenuItem("Open Dashboard", "Open the configurator in your browser")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop the server and quit")

	// Start the backend Dart process
	go startBackend()

	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				openBrowser("http://localhost:8484")
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {
	// Clean up the backend process
	if backendCmd != nil && backendCmd.Process != nil {
		fmt.Println("Shutting down backend process...")
		backendCmd.Process.Kill()
	}
}

func startBackend() {
	// In development, we run the dart script. 
	// In production, we would execute the compiled binary.
	// We'll check if a compiled binary exists, otherwise fallback to dart run.
	
	dir, err := os.Getwd()
	if err != nil {
		fmt.Println("Error getting wd:", err)
		return
	}
	
	backendDir := filepath.Join(dir, "..", "backend")
	
	// Check if compiled binary exists
	binaryPath := filepath.Join(backendDir, "kdedeck_daemon")
	if _, err := os.Stat(binaryPath); err == nil {
		fmt.Println("Found compiled binary, executing native daemon...")
		backendCmd = exec.Command("./kdedeck_daemon")
	} else {
		fmt.Println("Compiled binary not found, falling back to Dart SDK...")
		backendCmd = exec.Command("dart", "run", "bin/backend.dart")
	}

	backendCmd.Dir = backendDir
	backendCmd.Stdout = os.Stdout
	backendCmd.Stderr = os.Stderr

	fmt.Println("Starting Deckboard Dart Backend...")
	err = backendCmd.Run()
	if err != nil {
		fmt.Println("Backend process exited with error:", err)
	}
}

func openBrowser(url string) {
	var err error
	switch runtime.GOOS {
	case "linux":
		err = exec.Command("xdg-open", url).Start()
	case "windows":
		err = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	case "darwin":
		err = exec.Command("open", url).Start()
	default:
		err = fmt.Errorf("unsupported platform")
	}
	if err != nil {
		fmt.Printf("Error opening browser: %v\n", err)
	}
}
