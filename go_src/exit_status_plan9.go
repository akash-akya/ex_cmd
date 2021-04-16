package main

import (
	"os"
	"os/exec"
	"syscall"
)

func getExitStatus(err error) int {
	switch e := err.(type) {
	case *exec.ExitError:
		switch s := e.ProcessState.Sys().(type) {
		case syscall.Waitmsg:
			return s.ExitStatus()
		}
	}
	return 1
}

func makeSignal(sig byte) os.Signal {
	switch sig {
	case 128:
		return syscall.Note("interrupt")
	case 129:
		return syscall.Note("sys: kill")
	case 15:
		return syscall.Note("kill")
	default:
		return syscall.Note("")
	}
}
