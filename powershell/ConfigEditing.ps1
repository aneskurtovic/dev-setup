# JSONC edits preserve comments and all bytes outside the selected root value.
if (-not ('DevSetup.JsonEdit' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Text.Json;
namespace DevSetup {
    public static class JsonEdit {
        public static string Set(string text, string key, string value) {
            var options = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
            using var document = JsonDocument.Parse(text, options);
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new ArgumentException("Expected JSON object");
            int matches = 0, count = 0;
            foreach (var p in document.RootElement.EnumerateObject()) { count++; if (p.Name == key) matches++; }
            if (matches > 1) throw new ArgumentException("Duplicate root property: " + key);
            using var replacement = JsonDocument.Parse(value);
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            var reader = new Utf8JsonReader(bytes, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
            reader.Read();
            int insert = (int)reader.BytesConsumed;
            while (reader.Read()) {
                if (reader.TokenType == JsonTokenType.PropertyName && reader.CurrentDepth == 1 && reader.GetString() == key) {
                    reader.Read();
                    int start = (int)reader.TokenStartIndex;
                    reader.Skip();
                    int end = (int)reader.BytesConsumed;
                    return Encoding.UTF8.GetString(bytes, 0, start) + value + Encoding.UTF8.GetString(bytes, end, bytes.Length-end);
                }
            }
            return Encoding.UTF8.GetString(bytes, 0, insert) + "\n  " + JsonSerializer.Serialize(key) + ": " + value + (count > 0 ? "," : "") + Encoding.UTF8.GetString(bytes, insert, bytes.Length-insert);
        }
    }
}
'@
}

function Set-JsonRootValue([string] $Text, [string] $Name, $Value) {
    [DevSetup.JsonEdit]::Set($Text, $Name, (ConvertTo-Json -InputObject $Value -Depth 100 -Compress))
}

function Write-AtomicBytes([string] $Path, [byte[]] $Bytes) {
    $parent = Split-Path $Path
    $null = New-Item -ItemType Directory -Path $parent -Force
    $temp = Join-Path $parent ([IO.Path]::GetRandomFileName())
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        [IO.File]::Move($temp, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp } }
}
