//go:build js && wasm

// Command tailnet builds a WebAssembly module that runs a full Tailscale node
// inside the web page, so the PWA can reach the ytp server over the tailnet
// without the Tailscale app / an OS-level VPN on the device.
//
// It is adapted from tailscale.com/cmd/tsconnect/wasm (BSD-3-Clause): the
// node talks to the control plane and DERP relays over WebSockets and runs
// TCP/IP in userspace (gVisor netstack). On top of that it exposes a binary,
// streaming fetch() so the app can make normal HTTP requests — including audio
// downloads and server-sent events — to tailnet hosts.
//
// JS API (global):
//
//	const node = newTailnet({ stateStorage, authKey?, hostname?, controlURL?, ephemeral? })
//	node.run({ notifyState(s), notifyNetMap(json), notifyBrowseToURL(url), notifyPanicRecover(err) })
//	node.login(); node.logout()
//	const res = await node.fetch({ url, method?, headers?: [k,v][], body?: Uint8Array })
//	res.status, res.statusText, res.headers  // [k,v][]
//	await res.read()   // Uint8Array chunk, or null at EOF
//	res.cancel()
package main

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"sync"
	"syscall/js"
	"time"

	_ "golang.org/x/crypto/x509roots/fallback" // browsers expose no system roots to Go
	"tailscale.com/control/controlclient"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnauth"
	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/ipn/ipnserver"
	"tailscale.com/ipn/store/mem"
	"tailscale.com/logpolicy"
	"tailscale.com/logtail"
	"tailscale.com/net/netns"
	"tailscale.com/net/tsdial"
	"tailscale.com/safesocket"
	"tailscale.com/tailcfg"
	"tailscale.com/tsd"
	"tailscale.com/wgengine"
	"tailscale.com/wgengine/netstack"
)

func main() {
	js.Global().Set("newTailnet", js.FuncOf(func(this js.Value, args []js.Value) any {
		if len(args) != 1 {
			return js.ValueOf("usage: newTailnet(config)")
		}
		return newTailnet(args[0])
	}))
	if cb := js.Global().Get("__tailnetReady"); cb.Type() == js.TypeFunction {
		cb.Invoke()
	}
	<-make(chan bool) // keep the Go runtime alive
}

func str(v js.Value, key, def string) string {
	if x := v.Get(key); x.Type() == js.TypeString && x.String() != "" {
		return x.String()
	}
	return def
}

func newTailnet(cfg js.Value) map[string]any {
	netns.SetEnabled(false)

	var store ipn.StateStore = new(mem.Store)
	if s := cfg.Get("stateStorage"); !s.IsUndefined() && !s.IsNull() {
		store = &jsStateStore{s}
	}
	controlURL := str(cfg, "controlURL", ipn.DefaultControlURL)
	authKey := str(cfg, "authKey", "")
	hostname := str(cfg, "hostname", "ytp-web")
	loginFlags := controlclient.LoginDefault
	if e := cfg.Get("ephemeral"); e.Type() == js.TypeBoolean && e.Bool() {
		loginFlags = controlclient.LoginEphemeral
	}

	lpc := getOrCreateLogPolicyConfig(store)
	lt := logtail.NewLogger(logtail.Config{
		Collection:   lpc.Collection,
		PrivateID:    lpc.PrivateID,
		CompressLogs: false, // compressed uploads need headers no-cors fetch can't send
		HTTPC:        &http.Client{Transport: &noCORSTransport{http.DefaultTransport}},
	}, log.Printf)
	logf := lt.Logf

	sys := tsd.NewSystem()
	sys.Set(store)
	dialer := &tsdial.Dialer{Logf: logf}
	dialer.SetBus(sys.Bus.Get())
	eng, err := wgengine.NewUserspaceEngine(logf, wgengine.Config{
		Dialer:        dialer,
		SetSubsystem:  sys.Set,
		ControlKnobs:  sys.ControlKnobs(),
		HealthTracker: sys.HealthTracker.Get(),
		ExtraRootCAs:  sys.ExtraRootCAs,
		Metrics:       sys.UserMetricsRegistry(),
		EventBus:      sys.Bus.Get(),
	})
	if err != nil {
		log.Fatal(err)
	}
	sys.Set(eng)

	ns, err := netstack.Create(logf, sys.Tun.Get(), eng, sys.MagicSock.Get(), dialer, sys.DNSManager.Get(), sys.ProxyMapper())
	if err != nil {
		log.Fatalf("netstack.Create: %v", err)
	}
	sys.Set(ns)
	ns.ProcessLocalIPs = true
	ns.ProcessSubnets = true
	dialer.UseNetstackForIP = func(netip.Addr) bool { return true }
	dialer.NetstackDialTCP = func(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
		c, err := ns.DialContextTCP(ctx, dst)
		if err != nil {
			return nil, err // avoid returning a typed-nil *gonet.TCPConn
		}
		return c, nil
	}
	dialer.NetstackDialUDP = func(ctx context.Context, dst netip.AddrPort) (net.Conn, error) {
		c, err := ns.DialContextUDP(ctx, dst)
		if err != nil {
			return nil, err
		}
		return c, nil
	}
	sys.NetstackRouter.Set(true)
	sys.Tun.Get().Start()

	srv := ipnserver.New(logf, lpc.PublicID, sys.Bus.Get(), sys.NetMon.Get())
	lb, err := ipnlocal.NewLocalBackend(logf, lpc.PublicID, sys, loginFlags)
	if err != nil {
		log.Fatalf("ipnlocal.NewLocalBackend: %v", err)
	}
	if err := ns.Start(lb); err != nil {
		log.Fatalf("netstack start: %v", err)
	}
	srv.SetLocalBackend(lb)

	n := &node{
		lb:         lb,
		srv:        srv,
		controlURL: controlURL,
		authKey:    authKey,
		hostname:   hostname,
		http: &http.Client{
			Transport: &http.Transport{
				// Setting DialContext makes net/http use Go's own HTTP stack over the
				// tailnet instead of the browser's fetch().
				DialContext:         dialer.UserDial,
				TLSClientConfig:     &tls.Config{},
				ForceAttemptHTTP2:   false,
				MaxIdleConnsPerHost: 6,
				IdleConnTimeout:     90 * time.Second,
				TLSHandshakeTimeout: 20 * time.Second,
			},
			// Hand redirects back to the app untouched.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}

	fn := func(f func(args []js.Value) any) js.Func {
		return js.FuncOf(func(this js.Value, args []js.Value) any { return f(args) })
	}
	return map[string]any{
		"run":    fn(func(a []js.Value) any { n.run(a[0]); return nil }),
		"login":  fn(func([]js.Value) any { go lb.StartLoginInteractive(context.Background()); return nil }),
		"logout": fn(func([]js.Value) any { n.logout(); return nil }),
		"fetch":  fn(func(a []js.Value) any { return n.fetch(a[0]) }),
	}
}

type node struct {
	lb         *ipnlocal.LocalBackend
	srv        *ipnserver.Server
	controlURL string
	authKey    string
	hostname   string
	http       *http.Client
}

var stateNames = map[ipn.State]string{
	ipn.NoState:          "NoState",
	ipn.InUseOtherUser:   "InUseOtherUser",
	ipn.NeedsLogin:       "NeedsLogin",
	ipn.NeedsMachineAuth: "NeedsMachineAuth",
	ipn.Stopped:          "Stopped",
	ipn.Starting:         "Starting",
	ipn.Running:          "Running",
}

type netMapNode struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
	Online    *bool    `json:"online,omitempty"`
	OS        string   `json:"os,omitempty"`
}

type netMap struct {
	Self          netMapNode   `json:"self"`
	MachineStatus string       `json:"machineStatus"`
	Peers         []netMapNode `json:"peers"`
	LockedOut     bool         `json:"lockedOut"`
}

func (n *node) run(cb js.Value) {
	notifyState := func(s ipn.State) { cb.Call("notifyState", stateNames[s]) }
	notifyState(ipn.NoState)

	n.lb.SetNotifyCallback(func(no ipn.Notify) {
		defer func() {
			if r := recover(); r != nil {
				cb.Call("notifyPanicRecover", fmt.Sprint(r))
			}
		}()
		if no.State != nil {
			notifyState(*no.State)
		}
		if no.SelfChange != nil {
			if nm := n.lb.NetMapWithPeers(); nm != nil {
				out := netMap{
					Self: netMapNode{Name: nm.SelfName()},
					MachineStatus: map[tailcfg.MachineStatus]string{
						tailcfg.MachineUnknown:      "MachineUnknown",
						tailcfg.MachineUnauthorized: "MachineUnauthorized",
						tailcfg.MachineAuthorized:   "MachineAuthorized",
						tailcfg.MachineInvalid:      "MachineInvalid",
					}[nm.GetMachineStatus()],
					LockedOut: nm.TKAEnabled && nm.SelfNode.KeySignature().Len() == 0,
				}
				for _, a := range nm.GetAddresses().All() {
					out.Self.Addresses = append(out.Self.Addresses, a.Addr().String())
				}
				for _, p := range nm.Peers {
					pn := netMapNode{Name: p.Name(), Online: p.Online().Clone(), OS: p.Hostinfo().OS()}
					if pn.Name == "" {
						pn.Name = p.Hostinfo().Hostname()
					}
					for _, a := range p.Addresses().All() {
						pn.Addresses = append(pn.Addresses, a.Addr().String())
					}
					out.Peers = append(out.Peers, pn)
				}
				if b, err := json.Marshal(out); err == nil {
					cb.Call("notifyNetMap", string(b))
				}
			}
		}
		if no.BrowseToURL != nil {
			cb.Call("notifyBrowseToURL", *no.BrowseToURL)
		}
	})

	go func() {
		err := n.lb.Start(ipn.Options{
			UpdatePrefs: &ipn.Prefs{
				ControlURL:  n.controlURL,
				RouteAll:    false,
				WantRunning: true,
				Hostname:    n.hostname,
			},
			AuthKey: n.authKey,
		})
		if err != nil {
			log.Printf("start: %v", err)
		}
	}()
	go func() {
		ln, err := safesocket.Listen("")
		if err != nil {
			log.Fatalf("safesocket.Listen: %v", err)
		}
		log.Fatalf("ipnserver exited: %v", n.srv.Run(context.Background(), ln))
	}()
}

func (n *node) logout() {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		n.lb.Logout(ctx, ipnauth.Self)
	}()
}

// fetch performs an HTTP request over the tailnet and returns a streaming response.
func (n *node) fetch(req js.Value) js.Value {
	url := req.Get("url").String()
	method := str(req, "method", "GET")
	var body io.Reader
	if b := req.Get("body"); b.Type() == js.TypeObject && b.Get("byteLength").Int() > 0 {
		buf := make([]byte, b.Get("byteLength").Int())
		js.CopyBytesToGo(buf, b)
		body = strings.NewReader(string(buf))
	}
	type header struct{ k, v string }
	var headers []header
	if h := req.Get("headers"); h.Type() == js.TypeObject {
		for i := 0; i < h.Length(); i++ {
			headers = append(headers, header{h.Index(i).Index(0).String(), h.Index(i).Index(1).String()})
		}
	}

	return promise(func() (any, error) {
		ctx, cancel := context.WithCancel(context.Background())
		hr, err := http.NewRequestWithContext(ctx, method, url, body)
		if err != nil {
			cancel()
			return nil, err
		}
		for _, h := range headers {
			hr.Header.Add(h.k, h.v)
		}
		res, err := n.http.Do(hr)
		if err != nil {
			cancel()
			return nil, err
		}

		hdrs := make([]any, 0, len(res.Header))
		for k, vs := range res.Header {
			for _, v := range vs {
				hdrs = append(hdrs, []any{strings.ToLower(k), v})
			}
		}

		var once sync.Once
		closeBody := func() { once.Do(func() { res.Body.Close(); cancel() }) }
		buf := make([]byte, 256*1024)
		return map[string]any{
			"status":     res.StatusCode,
			"statusText": http.StatusText(res.StatusCode),
			"headers":    hdrs,
			"read": js.FuncOf(func(this js.Value, args []js.Value) any {
				return promise(func() (any, error) {
					for {
						k, err := res.Body.Read(buf)
						if k > 0 {
							arr := js.Global().Get("Uint8Array").New(k)
							js.CopyBytesToJS(arr, buf[:k])
							return arr, nil
						}
						if errors.Is(err, io.EOF) {
							closeBody()
							return nil, nil
						}
						if err != nil {
							closeBody()
							return nil, err
						}
					}
				})
			}),
			"cancel": js.FuncOf(func(this js.Value, args []js.Value) any {
				closeBody()
				return nil
			}),
		}, nil
	})
}

// promise runs f on a goroutine and settles a JS Promise with its result.
func promise(f func() (any, error)) js.Value {
	handler := js.FuncOf(func(this js.Value, args []js.Value) any {
		resolve, reject := args[0], args[1]
		go func() {
			res, err := f()
			if err != nil {
				reject.Invoke(js.Global().Get("Error").New(err.Error()))
				return
			}
			if res == nil {
				resolve.Invoke(js.Null())
				return
			}
			resolve.Invoke(res)
		}()
		return nil
	})
	return js.Global().Get("Promise").New(handler)
}

type jsStateStore struct{ s js.Value }

func (s *jsStateStore) ReadState(id ipn.StateKey) ([]byte, error) {
	v := s.s.Call("getState", string(id))
	if v.Type() != js.TypeString || v.String() == "" {
		return nil, ipn.ErrStateNotExist
	}
	return hex.DecodeString(v.String())
}

func (s *jsStateStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.s.Call("setState", string(id), hex.EncodeToString(bs))
	return nil
}

const logPolicyStateKey = "log-policy"

func getOrCreateLogPolicyConfig(state ipn.StateStore) *logpolicy.Config {
	if b, err := state.ReadState(logPolicyStateKey); err == nil {
		if c, err := logpolicy.ConfigFromBytes(b); err == nil {
			return c
		}
	}
	c := logpolicy.NewConfig(logtail.CollectionNode)
	_ = state.WriteState(logPolicyStateKey, c.ToBytes())
	return c
}

// noCORSTransport forces no-cors mode for log uploads to servers without CORS headers.
type noCORSTransport struct{ http.RoundTripper }

func (t *noCORSTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	req.Header.Set("js.fetch:mode", "no-cors")
	resp, err := t.RoundTripper.RoundTrip(req)
	if err == nil {
		resp.StatusCode = http.StatusOK
		resp.Status = http.StatusText(http.StatusOK)
	}
	return resp, err
}
