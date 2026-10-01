using System;
using System.Data.SqlClient;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Threading;

[assembly: AssemblyTitle("DependencyDemo")]
[assembly: AssemblyProduct("Generic Hyper-V Dependency Demo")]
[assembly: AssemblyCompany("Lab demonstration")]
[assembly: AssemblyVersion("1.0.0.0")]

internal static class DependencyDemo
{
    private static readonly string HealthFile =
        Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "traffic-health.txt");

    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--self-test")
        {
            Console.WriteLine("DependencyDemo argument/assembly self-test passed.");
            return 0;
        }
        if (args.Length == 2 && args[0] == "listen")
        {
            int port;
            if (!int.TryParse(args[1], out port) || port < 1024 || port > 65535) return 2;
            return Listen(port);
        }
        if ((args.Length == 3 || args.Length == 4) && args[0] == "client")
        {
            Client(args[1], args[2], args.Length == 4 ? args[3] : null);
            return 0;
        }
        Console.Error.WriteLine("Usage: listen PORT | client APP_FQDN FILE_FQDN [SQL_FQDN]");
        return 2;
    }

    private static int Listen(int port)
    {
        TcpListener listener = new TcpListener(IPAddress.Any, port);
        try
        {
            listener.Start();
            while (true)
            {
                TcpClient client = listener.AcceptTcpClient();
                ThreadPool.QueueUserWorkItem(delegate(object state)
                {
                    using (TcpClient peer = (TcpClient)state)
                    {
                        try
                        {
                            byte[] data = new byte[256];
                            NetworkStream stream = peer.GetStream();
                            while (stream.Read(data, 0, data.Length) > 0) { }
                        }
                        catch (IOException) { }
                        catch (SocketException) { }
                    }
                }, client);
            }
        }
        catch (SocketException) { return 3; }
        finally { listener.Stop(); }
    }

    private static void Client(string app, string files, string sql)
    {
        while (true)
        {
            try
            {
                using (TcpClient tcp = new TcpClient())
                {
                    IAsyncResult connect = tcp.BeginConnect(app, 9500, null, null);
                    using (connect.AsyncWaitHandle)
                    {
                        if (!connect.AsyncWaitHandle.WaitOne(15000)) throw new IOException();
                        tcp.EndConnect(connect);
                    }
                    // Real SMB I/O authenticates as the domain computer under SYSTEM.
                    using (FileStream smb = new FileStream(@"\\" + files + @"\DemoData\sample.txt",
                        FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (SqlConnection database = sql == null ? null : new SqlConnection(
                        "Data Source=" + sql + ",1433;Initial Catalog=master;Integrated Security=SSPI;" +
                        "Pooling=false;Connect Timeout=15;Application Name=DependencyDemo"))
                    {
                        if (database != null) database.Open();
                        DateTime until = DateTime.UtcNow.AddMinutes(12);
                        while (DateTime.UtcNow < until)
                        {
                            tcp.GetStream().WriteByte(10);
                            smb.Position = 0;
                            if (smb.ReadByte() < 0) throw new IOException();
                            HttpWebRequest request = (HttpWebRequest)WebRequest.Create("http://" + app + "/");
                            request.Timeout = 15000;
                            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                            {
                                if (response.StatusCode != HttpStatusCode.OK) throw new IOException();
                            }
                            if (database != null)
                            {
                                using (SqlCommand command = database.CreateCommand())
                                {
                                    command.CommandText = "SELECT 1";
                                    command.CommandTimeout = 10;
                                    command.ExecuteScalar();
                                }
                            }
                            WriteHealth(database == null ? "TCP=OK;HTTP=OK;SMB=OK" : "TCP=OK;HTTP=OK;SMB=OK;SQL=OK");
                            Thread.Sleep(30000);
                        }
                    }
                }
            }
            catch (Exception)
            {
                // Only generic health is persisted, not hostnames, usernames or exceptions.
                WriteHealth("CONNECTION_FAILED");
            }
            Thread.Sleep(10000);
        }
    }

    private static void WriteHealth(string result)
    {
        try
        {
            File.WriteAllLines(HealthFile, new string[] { DateTime.UtcNow.ToString("o"), result });
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
