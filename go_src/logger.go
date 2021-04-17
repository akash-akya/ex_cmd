package main

import (
	"io"
	"log"
	"os"
)

var logger *log.Logger

func initLogger(flag string) {
	var file io.Writer
	switch flag {
	case "":
		file = NullReadWriteCloser{
			Signal: make(chan struct{}, 1),
		}
	case "|1":
		file = os.Stdout
	case "|2":
		file = os.Stderr
	default:
		var err error
		file, err = os.OpenFile(flag, os.O_CREATE|os.O_WRONLY, 0666)
		fatalIf(err)
	}
	logger = log.New(file, "[odu]: ", log.Lmicroseconds)
}
