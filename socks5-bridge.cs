using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;

// Chrome speaks SOCKS5 without authentication; this loopback bridge adds it upstream.
public sealed class QueueSocksBridge : IDisposable
{
    readonly TcpListener listener;
    readonly CancellationTokenSource stop = new CancellationTokenSource();
    readonly ConcurrentDictionary<TcpClient, TcpClient> connections = new ConcurrentDictionary<TcpClient, TcpClient>();
    readonly string host;
    readonly int upstreamPort;
    readonly byte[] authentication;
    int reported;
    public int Port { get; private set; }

    public QueueSocksBridge(string host, int port, string user, string password)
    {
        authentication = AuthenticationPacket(user, password);
        this.host = host;
        upstreamPort = port;
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Task.Run((Func<Task>)Accept);
    }

    public static byte[] AuthenticationPacket(string user, string password)
    {
        byte[] u = Encoding.UTF8.GetBytes(user), p = Encoding.UTF8.GetBytes(password);
        if (u.Length < 1 || u.Length > 255 || p.Length < 1 || p.Length > 255)
            throw new ArgumentException("SOCKS5: usuario y clave requieren entre 1 y 255 bytes UTF-8.");
        byte[] packet = new byte[3 + u.Length + p.Length];
        packet[0] = 1; packet[1] = (byte)u.Length;
        Buffer.BlockCopy(u, 0, packet, 2, u.Length);
        packet[2 + u.Length] = (byte)p.Length;
        Buffer.BlockCopy(p, 0, packet, 3 + u.Length, p.Length);
        return packet;
    }

    static async Task<byte[]> Read(Stream stream, int count, CancellationToken token)
    {
        byte[] bytes = new byte[count];
        int offset = 0;
        while (offset < count)
        {
            int n = await stream.ReadAsync(bytes, offset, count - offset, token).ConfigureAwait(false);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
        return bytes;
    }

    public static async Task Authenticate(Stream local, Stream remote, byte[] packet, CancellationToken token)
    {
        byte[] hello = await Read(local, 2, token).ConfigureAwait(false);
        if (hello[0] != 5 || hello[1] == 0) throw new IOException("Version SOCKS5 invalida.");
        byte[] methods = await Read(local, hello[1], token).ConfigureAwait(false);
        if (Array.IndexOf(methods, (byte)0) < 0)
        {
            await local.WriteAsync(new byte[] { 5, 255 }, 0, 2, token).ConfigureAwait(false);
            throw new IOException("Metodo local no admitido.");
        }
        await local.WriteAsync(new byte[] { 5, 0 }, 0, 2, token).ConfigureAwait(false);
        await remote.WriteAsync(new byte[] { 5, 1, 2 }, 0, 3, token).ConfigureAwait(false);
        byte[] choice = await Read(remote, 2, token).ConfigureAwait(false);
        if (choice[0] != 5 || choice[1] != 2) throw new IOException("El proxy no acepta autenticacion.");
        await remote.WriteAsync(packet, 0, packet.Length, token).ConfigureAwait(false);
        byte[] result = await Read(remote, 2, token).ConfigureAwait(false);
        if (result[0] != 1 || result[1] != 0) throw new IOException("Autenticacion rechazada.");
        // The upstream handles CONNECT/address parsing; forward the remaining SOCKS5 exchange unchanged.
    }

    async Task Accept()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                TcpClient local = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
                if (stop.IsCancellationRequested) { local.Dispose(); break; }
                Task ignored = Serve(local);
            }
        }
        catch (ObjectDisposedException) { }
        catch (SocketException) { }
    }

    async Task Serve(TcpClient local)
    {
        using (local)
        using (TcpClient remote = new TcpClient())
        using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
        {
            connections[local] = remote;
            try
            {
                timeout.CancelAfter(15000);
                using (timeout.Token.Register(() => { local.Dispose(); remote.Dispose(); }))
                {
                    timeout.Token.ThrowIfCancellationRequested();
                    await remote.ConnectAsync(host, upstreamPort).ConfigureAwait(false);
                    await Authenticate(local.GetStream(), remote.GetStream(), authentication, timeout.Token).ConfigureAwait(false);
                    timeout.CancelAfter(Timeout.Infinite);
                    Task outgoing = local.GetStream().CopyToAsync(remote.GetStream(), 81920, timeout.Token);
                    Task incoming = remote.GetStream().CopyToAsync(local.GetStream(), 81920, timeout.Token);
                    await Task.WhenAny(outgoing, incoming).ConfigureAwait(false);
                    timeout.Cancel();
                    try { await Task.WhenAll(outgoing, incoming).ConfigureAwait(false); } catch { }
                }
            }
            catch (Exception)
            {
                if (!stop.IsCancellationRequested && Interlocked.Exchange(ref reported, 1) == 0)
                    Console.Error.WriteLine("SOCKS5 local:{0}: conexion/autenticacion fallida; revisa proveedor y credenciales.", Port);
            }
            finally { TcpClient ignored; connections.TryRemove(local, out ignored); }
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Stop();
        foreach (var pair in connections) { pair.Key.Dispose(); pair.Value.Dispose(); }
    }
}
