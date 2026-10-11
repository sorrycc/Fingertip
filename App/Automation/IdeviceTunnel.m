#import "IdeviceTunnel.h"
#include "idevice.h"
#include <arpa/inet.h>
#include <pthread.h>

@implementation TunnelServiceInfo
@end

// Forked from TouchSynthesis's IdeviceTunnel.m for iOS 26.4+, where lockdownd (62078) no longer accepts
// connections through the LocalDevVPN loopback. Transport is now RemotePairing (RPPairing) to port 49152,
// the same path StikDebug uses: rp_pairing_file_read → tunnel_create_rppairing → adapter + RSD handshake.
// The heartbeat runs over RSD on a long-lived tunnel; everything above (RSD proxies, screenshots) is unchanged.

/// Tracks one running proxy bridge (local TCP <-> ReadWriteOpaque stream).
@interface _ProxyBridge : NSObject
@property (nonatomic, assign) int serverFD;
@property (nonatomic, assign) int clientFD;
@property (nonatomic, assign) uint16_t localPort;
@property (nonatomic, assign) struct AdapterHandle *adapter;
@property (nonatomic, assign) struct RsdHandshakeHandle *handshake;
@property (nonatomic, assign) struct ReadWriteOpaque *stream;
@property (nonatomic, assign) BOOL running;
@end

@implementation _ProxyBridge
- (void)dealloc {
    [self stop];
}
- (void)stop {
    _running = NO;
    if (_clientFD > 0) { close(_clientFD); _clientFD = -1; }
    if (_serverFD > 0) { close(_serverFD); _serverFD = -1; }
    if (_stream) { idevice_stream_free(_stream); _stream = NULL; }
    if (_handshake) { rsd_handshake_free(_handshake); _handshake = NULL; }
    if (_adapter) { adapter_free(_adapter); _adapter = NULL; }
}
@end

@implementation IdeviceTunnel {
    // Heartbeat (marco/polo) over a long-lived RPPairing tunnel
    struct AdapterHandle *_heartbeatAdapter;
    struct RsdHandshakeHandle *_heartbeatHandshake;
    struct HeartbeatClientHandle *_heartbeatClient;
    BOOL _heartbeatRunning;
    int _heartbeatToken;

    // Saved connection params
    NSString *_savedPairingPath;
    NSString *_savedDeviceIP;
    uint16_t _savedPort;
    BOOL _connected;

    // Active proxy bridges
    NSMutableArray<_ProxyBridge *> *_proxies;
}

static int sGlobalHeartbeatToken = 0;

- (BOOL)isConnected {
    return _connected;
}

- (BOOL)heartbeatRunning {
    return _heartbeatRunning;
}

// MARK: - RemotePairing tunnel

/// Opens an RPPairing tunnel to the device. Caller frees adapter and handshake.
static NSString *CreateRPTunnel(NSString *pairingPath, NSString *deviceIP, uint16_t port,
                                struct AdapterHandle **outAdapter, struct RsdHandshakeHandle **outHandshake) {
    struct RpPairingFileHandle *pairing = NULL;
    IdeviceFfiError *err = rp_pairing_file_read([pairingPath UTF8String], &pairing);
    if (err != NULL) {
        NSString *msg = [NSString stringWithFormat:@"RemotePairing file read failed: %s", err->message];
        idevice_error_free(err);
        return msg;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (inet_pton(AF_INET, [deviceIP UTF8String], &addr.sin_addr) != 1) {
        rp_pairing_file_free(pairing);
        return @"Invalid device IP address";
    }

    err = tunnel_create_rppairing((const idevice_sockaddr *)&addr, (idevice_socklen_t)sizeof(addr), "fingertip",
                                  pairing, NULL, NULL, outAdapter, outHandshake);
    rp_pairing_file_free(pairing);
    if (err != NULL) {
        NSString *msg = [NSString stringWithFormat:@"RPPairing tunnel to %@:%u failed: %s", deviceIP, port, err->message];
        idevice_error_free(err);
        return msg;
    }
    if (*outAdapter == NULL || *outHandshake == NULL) return @"RPPairing tunnel returned no handles";
    return nil;
}

// MARK: - Connect (starts heartbeat only)

- (nullable NSString *)connectWithPairingFile:(NSString *)pairingFilePath
                                     deviceIP:(NSString *)deviceIP
                                         port:(uint16_t)port {
    [self disconnect];
    _savedPairingPath = [pairingFilePath copy];
    _savedDeviceIP = [deviceIP copy];
    _savedPort = port;

    // Long-lived tunnel for the heartbeat, which keeps the developer services (and DDI) alive.
    NSString *tunnelErr = CreateRPTunnel(pairingFilePath, deviceIP, port, &_heartbeatAdapter, &_heartbeatHandshake);
    if (tunnelErr != nil) return tunnelErr;

    IdeviceFfiError *err = heartbeat_connect_rsd(_heartbeatAdapter, _heartbeatHandshake, &_heartbeatClient);
    if (err != NULL) {
        NSString *msg = [NSString stringWithFormat:@"Heartbeat connect failed: %s", err->message];
        idevice_error_free(err);
        [self disconnect];
        return msg;
    }

    _heartbeatRunning = YES;
    sGlobalHeartbeatToken++;
    _heartbeatToken = sGlobalHeartbeatToken;
    _connected = YES;

    int myToken = _heartbeatToken;
    struct HeartbeatClientHandle *client = _heartbeatClient;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        uint64_t interval = 15;
        NSLog(@"[IdeviceTunnel] Heartbeat thread started (token=%d)", myToken);
        while (myToken == sGlobalHeartbeatToken) {
            uint64_t newInterval = 0;
            IdeviceFfiError *hbErr = heartbeat_get_marco(client, interval, &newInterval);
            if (hbErr != NULL) {
                NSLog(@"[IdeviceTunnel] Heartbeat marco failed: %s", hbErr->message);
                idevice_error_free(hbErr);
                break;
            }
            if (myToken != sGlobalHeartbeatToken) break;
            interval = newInterval + 5;
            hbErr = heartbeat_send_polo(client);
            if (hbErr != NULL) {
                NSLog(@"[IdeviceTunnel] Heartbeat polo failed: %s", hbErr->message);
                idevice_error_free(hbErr);
                break;
            }
        }
        NSLog(@"[IdeviceTunnel] Heartbeat thread exiting (token=%d)", myToken);
    });

    return nil;
}

// MARK: - Fresh tunnel helper

/// Creates a fresh RPPairing tunnel + adapter + RSD handshake. Caller frees adapter and handshake.
- (nullable NSString *)_freshTunnelWithAdapter:(struct AdapterHandle **)outAdapter
                                     handshake:(struct RsdHandshakeHandle **)outHandshake {
    if (!_connected || !_savedPairingPath || !_savedDeviceIP) {
        return @"Not connected — call connect first";
    }
    return CreateRPTunnel(_savedPairingPath, _savedDeviceIP, _savedPort, outAdapter, outHandshake);
}

// MARK: - Screenshot

- (nullable NSData *)takeScreenshotAndReturnError:(NSString *_Nullable *_Nullable)outError {
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    NSString *tunnelErr = [self _freshTunnelWithAdapter:&adapter handshake:&handshake];
    if (tunnelErr != nil) {
        if (outError) *outError = tunnelErr;
        return nil;
    }

    // Create RemoteServer
    struct RemoteServerHandle *remoteServer = NULL;
    IdeviceFfiError *err = remote_server_connect_rsd(adapter, handshake, &remoteServer);
    if (err != NULL) {
        if (outError) *outError = [NSString stringWithFormat:@"RemoteServer: %s", err->message];
        idevice_error_free(err);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return nil;
    }

    // Create ScreenshotClient
    struct ScreenshotClientHandle *ssClient = NULL;
    err = screenshot_client_new(remoteServer, &ssClient);
    if (err != NULL) {
        if (outError) *outError = [NSString stringWithFormat:@"ScreenshotClient: %s", err->message];
        idevice_error_free(err);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return nil;
    }

    // Take screenshot
    uint8_t *pngData = NULL;
    uintptr_t pngLen = 0;
    err = screenshot_client_take_screenshot(ssClient, &pngData, &pngLen);
    if (err != NULL) {
        if (outError) *outError = [NSString stringWithFormat:@"Screenshot: %s", err->message];
        idevice_error_free(err);
        screenshot_client_free(ssClient);
        remote_server_free(remoteServer);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return nil;
    }

    // Copy PNG data before freeing FFI memory
    NSData *result = nil;
    if (pngData != NULL && pngLen > 0) {
        result = [NSData dataWithBytes:pngData length:pngLen];
        idevice_data_free(pngData, pngLen);
    }

    // Cleanup
    screenshot_client_free(ssClient);
    remote_server_free(remoteServer);
    rsd_handshake_free(handshake);
    adapter_free(adapter);

    if (result == nil && outError) {
        *outError = @"Screenshot returned empty data";
    }
    return result;
}

// MARK: - RSD TCP Proxy

- (uint16_t)createProxyToRSDService:(NSString *)serviceName
                              error:(NSString *_Nullable *_Nullable)outError {
    if (!_proxies) _proxies = [NSMutableArray new];

    // Step 1: Create fresh CDTunnel
    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    NSString *tunnelErr = [self _freshTunnelWithAdapter:&adapter handshake:&handshake];
    if (tunnelErr != nil) {
        if (outError) *outError = tunnelErr;
        return 0;
    }

    // Step 2: Find service port via RSD
    struct CRsdService *svcInfo = NULL;
    IdeviceFfiError *err = rsd_get_service_info(handshake, [serviceName UTF8String], &svcInfo);
    if (err != NULL) {
        if (outError) *outError = [NSString stringWithFormat:@"RSD service '%@': %s", serviceName, err->message];
        idevice_error_free(err);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return 0;
    }

    uint16_t servicePort = svcInfo->port;
    NSLog(@"[Proxy] Found %@ on port %u", serviceName, servicePort);
    rsd_free_service(svcInfo);

    // Step 3: Connect to the service port via adapter
    struct ReadWriteOpaque *stream = NULL;
    err = adapter_connect(adapter, servicePort, &stream);
    if (err != NULL) {
        if (outError) *outError = [NSString stringWithFormat:@"adapter_connect to port %u: %s", servicePort, err->message];
        idevice_error_free(err);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return 0;
    }

    // Step 4: Create local TCP server socket on 127.0.0.1:0
    int serverFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (serverFD < 0) {
        if (outError) *outError = @"socket() failed for local proxy";
        idevice_stream_free(stream);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return 0;
    }

    int reuse = 1;
    setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in localAddr;
    memset(&localAddr, 0, sizeof(localAddr));
    localAddr.sin_family = AF_INET;
    localAddr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    localAddr.sin_port = 0; // random port

    if (bind(serverFD, (struct sockaddr *)&localAddr, sizeof(localAddr)) < 0) {
        if (outError) *outError = [NSString stringWithFormat:@"bind() failed: errno=%d", errno];
        close(serverFD);
        idevice_stream_free(stream);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return 0;
    }

    if (listen(serverFD, 1) < 0) {
        if (outError) *outError = [NSString stringWithFormat:@"listen() failed: errno=%d", errno];
        close(serverFD);
        idevice_stream_free(stream);
        rsd_handshake_free(handshake);
        adapter_free(adapter);
        return 0;
    }

    // Get assigned port
    struct sockaddr_in boundAddr;
    socklen_t addrLen = sizeof(boundAddr);
    getsockname(serverFD, (struct sockaddr *)&boundAddr, &addrLen);
    uint16_t localPort = ntohs(boundAddr.sin_port);

    NSLog(@"[Proxy] Listening on 127.0.0.1:%u -> %@:%u", localPort, serviceName, servicePort);

    // Step 5: Create bridge object
    _ProxyBridge *bridge = [_ProxyBridge new];
    bridge.serverFD = serverFD;
    bridge.clientFD = -1;
    bridge.localPort = localPort;
    bridge.adapter = adapter;
    bridge.handshake = handshake;
    bridge.stream = stream;
    bridge.running = YES;
    [_proxies addObject:bridge];

    // Step 6: Start bridge threads
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"[Proxy] Waiting for DTXConnection on port %u...", localPort);

        // Set accept timeout (30s)
        struct timeval tv = {.tv_sec = 30, .tv_usec = 0};
        setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        struct sockaddr_in clientAddr;
        socklen_t clientLen = sizeof(clientAddr);
        int clientFD = accept(serverFD, (struct sockaddr *)&clientAddr, &clientLen);
        if (clientFD < 0) {
            NSLog(@"[Proxy] accept() failed: errno=%d", errno);
            bridge.running = NO;
            return;
        }

        bridge.clientFD = clientFD;
        NSLog(@"[Proxy] DTXConnection accepted on port %u", localPort);

        // Bridge thread A: local socket -> readwrite_send
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            uint8_t buf[16384];
            while (bridge.running) {
                ssize_t n = recv(clientFD, buf, sizeof(buf), 0);
                if (n <= 0) {
                    NSLog(@"[Proxy->Device] recv returned %zd, errno=%d", n, errno);
                    bridge.running = NO;
                    break;
                }
                IdeviceFfiError *sendErr = readwrite_send(stream, buf, (uintptr_t)n);
                if (sendErr != NULL) {
                    NSLog(@"[Proxy->Device] readwrite_send failed: %s", sendErr->message);
                    idevice_error_free(sendErr);
                    bridge.running = NO;
                    break;
                }
            }
            NSLog(@"[Proxy->Device] Thread exiting for port %u", localPort);
        });

        // Bridge thread B: readwrite_recv -> local socket
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            uint8_t buf[16384];
            while (bridge.running) {
                uintptr_t bytesRead = 0;
                IdeviceFfiError *recvErr = readwrite_recv(stream, buf, &bytesRead, sizeof(buf));
                if (recvErr != NULL) {
                    NSLog(@"[Device->Proxy] readwrite_recv failed: %s", recvErr->message);
                    idevice_error_free(recvErr);
                    bridge.running = NO;
                    break;
                }
                if (bytesRead == 0) {
                    NSLog(@"[Device->Proxy] readwrite_recv returned 0 bytes");
                    bridge.running = NO;
                    break;
                }
                uintptr_t totalSent = 0;
                while (totalSent < bytesRead && bridge.running) {
                    ssize_t n = send(clientFD, buf + totalSent, bytesRead - totalSent, 0);
                    if (n <= 0) {
                        NSLog(@"[Device->Proxy] send returned %zd", n);
                        bridge.running = NO;
                        break;
                    }
                    totalSent += n;
                }
            }
            NSLog(@"[Device->Proxy] Thread exiting for port %u", localPort);
        });
    });

    return localPort;
}

- (void)stopAllProxies {
    for (_ProxyBridge *bridge in _proxies) {
        [bridge stop];
    }
    [_proxies removeAllObjects];
}

- (BOOL)pingTunnel {
    if (!_connected) return NO;

    struct AdapterHandle *adapter = NULL;
    struct RsdHandshakeHandle *handshake = NULL;
    NSString *err = [self _freshTunnelWithAdapter:&adapter handshake:&handshake];
    if (err != nil) return NO;

    // Successfully created a fresh tunnel — tear it down
    rsd_handshake_free(handshake);
    adapter_free(adapter);
    return YES;
}

// MARK: - Disconnect

- (void)disconnect {
    // Stop proxies
    [self stopAllProxies];

    // Stop heartbeat
    if (_heartbeatRunning) {
        sGlobalHeartbeatToken++;
        _heartbeatRunning = NO;
    }
    if (_heartbeatClient) {
        heartbeat_client_free(_heartbeatClient);
        _heartbeatClient = NULL;
    }
    if (_heartbeatHandshake) {
        rsd_handshake_free(_heartbeatHandshake);
        _heartbeatHandshake = NULL;
    }
    if (_heartbeatAdapter) {
        adapter_free(_heartbeatAdapter);
        _heartbeatAdapter = NULL;
    }
    _connected = NO;
}

- (void)dealloc {
    [self disconnect];
}

@end
