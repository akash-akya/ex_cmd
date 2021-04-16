package main

import (
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

	args := flag.Args()
	validateArgs(args)

	err := execute(*cdFlag, args)
	if err != nil {
		os.Exit(getExitStatus(err))
	}
}

func validateArgs(args []string) {
	if len(args) < 1 {
		dieUsage("Not enough arguments.")
	}

	if *protocolVersionFlag != "1.0" {
		dieUsage(fmt.Sprintf("Invalid version specified: %v  Supported version: %v", *protocolVersionFlag, ProtocolVersion))
	}

	logger.Printf("dir:%v, log:%v, protocol_version:%v, args:%v\n", *cdFlag, *logFlag, *protocolVersionFlag, args)
}

func notFifo(path string) bool {
	info, err := os.Stat(path)
	return os.IsNotExist(err) || info.Mode()&os.ModeNamedPipe == 0
}
