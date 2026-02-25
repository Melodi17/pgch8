namespace pgch8;

using System.Text;
using Npgsql;

class Program
{
    private static NpgsqlConnection _conn;
    private static Screen _screen;
    
    static void Main(string[] args)
    {
        CreateConnection();
        Program.Reset();

        CreateScreen();
        WriteRom("/Users/melodidey/Source/csharp/pgch8/test_opcode.ch8");
        WriteFont([
            0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
            0x20, 0x60, 0x20, 0x20, 0x70, // 1
            0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
            0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
            0x90, 0x90, 0xF0, 0x10, 0x10, // 4
            0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
            0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
            0xF0, 0x10, 0x20, 0x40, 0x40, // 7
            0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
            0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
            0xF0, 0x90, 0xF0, 0x90, 0x90, // A
            0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
            0xF0, 0x80, 0x80, 0x80, 0xF0, // C
            0xE0, 0x90, 0x90, 0x90, 0xE0, // D
            0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
            0xF0, 0x80, 0xF0, 0x80, 0x80  // F
        ]);

        while (true)
        {
            Program.Clock();
            if (Program.IsScreenDirty())
            {
                _screen.Pixels = Program.GetScreenPixels();
                _screen.Render();
                Program.MarkScreenClean();
            }
            
            Thread.Sleep(1000 / 60);
        }
    }
    
    private static void Reset()
    {
        Program.Execute("select private.reset();");
    }
    
    private static void Clock()
    {
        Program.Execute("select private.clock();");
    }
    
    private static bool IsScreenDirty()
    {
        return Program.QuerySingle<bool>("select private.is_screen_dirty();");
    }
    
    private static void MarkScreenClean()
    {
        Program.Execute("select private.mark_screen_clean();");
    }
    
    private static bool[] GetScreenPixels()
    {
        return Program.Query(
            "select value from private.display order by i;",
            reader =>
            {
                List<bool> pixels = new();
                while (reader.Read())
                {
                    pixels.Add(reader.GetBoolean(0));
                }
                return pixels.ToArray();
            });
    }

    private static void CreateConnection()
    {
        Program._conn = new("Host=localhost;Username=melodidey;Database=emulator");
        Program._conn.Open();
    }

    private static void CreateScreen()
    {
        int screenWidth = QuerySingle<int>("select value from private.constants where label = 'Screen Width';");
        int screenHeight = QuerySingle<int>("select value from private.constants where label = 'Screen Height';");
        
        Program._screen = new Screen(screenWidth, screenHeight);
    }
    
    private static void WriteRom(string path)
    {
        byte[] rom = File.ReadAllBytes(path);

        int romStart = QuerySingle<int>(
            "select value_word from private.constants where label = 'Program Start';"
        );

        for (int i = 0; i < rom.Length; i++)
        {
            Execute(
                "update private.memory set value = @p1 where address = @p0;",
                romStart + i,
                rom[i]
            );
        }
    }

    private static void WriteFont(byte[] font)
    {
        int fontStart = QuerySingle<int>(
            "select value_word from private.constants where label = 'Font Start';"
        );

        for (int i = 0; i < font.Length; i++)
        {
            Execute(
                "update private.memory set value = @p1 where address = @p0;",
                fontStart + i,
                font[i]
            );
        }
    }

    static void Execute(string query, params object[] parameters)
    {
        using var cmd = new NpgsqlCommand(query, Program._conn);
        for (int i = 0; i < parameters.Length; i++)
        {
            cmd.Parameters.AddWithValue($"@p{i}", parameters[i]);
        }
        cmd.ExecuteNonQuery();
    }
    
    static T Query<T>(string query, Func<NpgsqlDataReader, T> map)
    {
        using var cmd = new NpgsqlCommand(query, Program._conn);
        using var reader = cmd.ExecuteReader();
        return map(reader);
    }
    
    static T QuerySingle<T>(string query)
    {
        try
        {
            return Query(query, reader =>
            {
                reader.Read();
                return reader.GetFieldValue<T>(0);
            }); 
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Error executing query '{query}': {ex.Message}");
            throw;
        }
    }
}

class Screen
{
    public int Width { get; set; }
    public int Height { get; set; }
    public bool[] Pixels { get; set; }
    
    public Screen(int width, int height)
    {
        Width = width;
        Height = height;
        Pixels = new bool[width * height];
    }

    public void Render()
    {
        StringBuilder sb = new();
        for (int i = 0; i < Pixels.Length; i++)
        {
            sb.Append(Pixels[i] ? "#" : " ");
            if ((i + 1) % Width == 0)
                sb.AppendLine();
        }
        
        Console.Clear();
        Console.WriteLine(sb.ToString());
    }
}