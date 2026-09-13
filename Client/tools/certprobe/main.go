package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/quic-go/quic-go"
)

func main() {
	host := os.Args[1]
	port := os.Args[2]
	sni := os.Args[3]

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// 关键：InsecureSkipVerify 只用于"取证书"，拿到指纹后由 Xray 做 pinning 校验
	conf := &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h3"},
	}
	conn, err := quic.DialAddr(ctx, net.JoinHostPort(host, port), conf, nil)
	if err != nil {
		fmt.Println("dial err:", err)
		os.Exit(1)
	}
	defer conn.CloseWithError(0, "")

	st := conn.ConnectionState()
	if len(st.TLS.PeerCertificates) == 0 {
		// 触发一次握手以填充证书
		if _, err := conn.AcceptStream(ctx); err != nil {
			fmt.Println("no cert, handshake partially done:", err)
		}
		st = conn.ConnectionState()
	}
	certs := st.TLS.PeerCertificates
	if len(certs) == 0 {
		fmt.Println("未取到证书")
		os.Exit(1)
	}
	fmt.Printf("证书链长度: %d\n", len(certs))
	for i, c := range certs {
		sum := sha256.Sum256(c.Raw)
		fmt.Printf("  [%d] Subject=%s\n", i, c.Subject)
		fmt.Printf("      Issuer =%s\n", c.Issuer)
		fmt.Printf("      SAN    =%v\n", c.DNSNames)
		fmt.Printf("      SHA256 =%s\n", hex.EncodeToString(sum[:]))
	}
}
