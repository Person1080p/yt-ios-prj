//go:build !js

// Prints the -tags value tailscale uses for its own browser (tsconnect) build,
// which omits every feature a browser node doesn't need.
package main

import (
	"fmt"

	"tailscale.com/cmd/tsconnect/wasmbuild"
)

func main() { fmt.Print(wasmbuild.Tags()) }
