package main

import (
	"os/exec"
	"flag"
	"fmt"
	"os"
)

// Version of the odu
const Version = "0.1.0"

// Supported protocol version
const ProtocolVersion = "1.0"

const usage = "Usage: odu [options] -- <program> [<arg>...]"

var cdFlag = flag.String("cd", ".", "working directory for the spawned process")
var stderrFlag = flag.String("stderr", "console", "how to handle spawned process stderr stream")
var logFlag = flag.String("log", "", "enable logging")
var protocolVersionFlag = flag.String("protocol_version", "", "protocol version")
var versionFlag = flag.Bool("v", false, "print version and exit")

func main() {
	flag.Parse()

	initLogger(*logFlag)

	if *versionFlag {
		fmt.Printf("odu version: %s\nprotocol_version: %s", Version, ProtocolVersion)
		os.Exit(0)
	}

	switch *stderrFlag {
	case "console":
	case "disable":
	case "redirect_to_stdout":
	default:
		logger.Printf("invalid stderr flag")
		os.Exit(3)
	}

	args := flag.Args()
	validateArgs(args)

	err := execute(*cdFlag, args, *stderrFlag)

	if err == nil {
		os.Exit(0)
	}

	if exitError, ok := err.(*exec.Error); ok {
		// This shouldn't really happen in practice because we check for
		// program existence in Elixir, before launching odu
		logger.Printf("Command exited with error: %v", exitError)
	} else  {
		logger.Printf("Command exited with unknown errors", err)
	}

	os.Exit(3)
}

func validateArgs(args []string) {
	if len(args) < 1 {
		dieUsage("Not enough arguments.")
	}

	if *protocolVersionFlag != "1.0" {
		dieUsage(fmt.Sprintf("Invalid version specified: %v  Supported version: %v", *protocolVersionFlag, ProtocolVersion))
	}

	logger.Printf("dir:%v, log:%v, protocol_version:%v, stderr: %v, args:%v\n", *cdFlag, *logFlag, *protocolVersionFlag, *stderrFlag, args)
}

func notFifo(path string) bool {
	info, err := os.Stat(path)
	return os.IsNotExist(err) || info.Mode()&os.ModeNamedPipe == 0
}
