// Command dataplane-function is a Crossplane Composition Function.
//
// It composes an advanced dataplane workload (Namespace, ConfigMap,
// Deployment, Service) for the XDataPlaneAdvanced composite resource,
// submitting each as a provider-kubernetes Object targeting the spoke
// cluster named in spec.parameters.spoke.
package main

import (
	"flag"
	"log"
	"os"

	function "github.com/crossplane/function-sdk-go"
)

func main() {
	debug := flag.Bool("debug", false, "Emit debug logs.")
	insecure := flag.Bool("insecure", false, "Run without mTLS credentials. Insecure, use only for development.")
	listenAddr := flag.String("listen", ":9443", "Address at which to listen for gRPC connections.")
	tlsCertsDir := flag.String("tls-certs-dir", os.Getenv("TLS_SERVER_CERTS_DIR"), "Directory containing the server mTLS certificates. Crossplane sets TLS_SERVER_CERTS_DIR when it starts this Function.")
	flag.Parse()

	logger, err := function.NewLogger(*debug)
	if err != nil {
		log.Fatalf("cannot create logger: %v", err)
	}

	f := &Function{log: logger}

	err = function.Serve(f,
		function.Listen("tcp", *listenAddr),
		function.MTLSCertificates(*tlsCertsDir),
		function.Insecure(*insecure),
	)
	if err != nil {
		log.Fatalf("cannot serve function: %v", err)
	}
}
