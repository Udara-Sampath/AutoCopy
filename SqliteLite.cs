// Minimal read-only SQLite access via Windows' built-in winsqlite3.dll.
// Compiled at startup by AutoCopy.ps1 via Add-Type (C# 5, .NET Framework).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AutoCopyNative
{
    public static class Sqlite
    {
        const string Dll = "winsqlite3.dll";
        const int SQLITE_ROW = 100, SQLITE_OPEN_READONLY = 1, SQLITE_OPEN_URI = 0x40;
        const int SQLITE_INTEGER = 1, SQLITE_FLOAT = 2, SQLITE_TEXT = 3, SQLITE_BLOB = 4;

        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare16_v2(IntPtr db, [MarshalAs(UnmanagedType.LPWStr)] string sql, int nBytes, out IntPtr stmt, IntPtr tail);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_type(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_column_int64(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text16(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_blob(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg16(IntPtr db);

        /// <summary>
        /// Runs a query against a database opened read-only and returns every row.
        /// Integers come back as long, text as string, blobs as byte[], NULL as null.
        /// </summary>
        public static List<object[]> Query(string path, string sql)
        {
            List<object[]> rows = new List<object[]>();
            string uri = "file:" + Uri.EscapeUriString(path.Replace('\\', '/')).Replace("#", "%23").Replace("?", "%3F") + "?mode=ro";
            byte[] name = System.Text.Encoding.UTF8.GetBytes(uri + "\0");
            IntPtr db;
            int rc = sqlite3_open_v2(name, out db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, IntPtr.Zero);
            try
            {
                if (rc != 0) throw new Exception("open failed: " + Error(db));
                sqlite3_busy_timeout(db, 2000);
                IntPtr stmt;
                if (sqlite3_prepare16_v2(db, sql, -1, out stmt, IntPtr.Zero) != 0) throw new Exception("query failed: " + Error(db));
                try
                {
                    int n = sqlite3_column_count(stmt);
                    while (sqlite3_step(stmt) == SQLITE_ROW)
                    {
                        object[] row = new object[n];
                        for (int i = 0; i < n; i++)
                        {
                            switch (sqlite3_column_type(stmt, i))
                            {
                                case SQLITE_INTEGER: row[i] = sqlite3_column_int64(stmt, i); break;
                                case SQLITE_FLOAT:
                                case SQLITE_TEXT: row[i] = Marshal.PtrToStringUni(sqlite3_column_text16(stmt, i)); break;
                                case SQLITE_BLOB:
                                    int len = sqlite3_column_bytes(stmt, i);
                                    byte[] b = new byte[len];
                                    if (len > 0) Marshal.Copy(sqlite3_column_blob(stmt, i), b, 0, len);
                                    row[i] = b; break;
                                default: row[i] = null; break;
                            }
                        }
                        rows.Add(row);
                    }
                }
                finally { sqlite3_finalize(stmt); }
            }
            finally { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
            return rows;
        }

        static string Error(IntPtr db)
        {
            if (db == IntPtr.Zero) return "unknown";
            return Marshal.PtrToStringUni(sqlite3_errmsg16(db));
        }
    }
}
