#property strict
#property script_show_inputs

input string   InpSymbol           = "NDX100";
input bool     InpAllLoadedSymbols = false;
input string   InpTimeframes      = "M1,M5,M15,M30,H1,H4,D1";
input string   InpOutputPrefix   = "";
input string   InpCsvDelimiter    = ",";
input bool     InpUseCommonDir    = true;
input bool     InpClosedBarsOnly  = true;
input bool     InpForceRebuildFromStart = false;
input bool     InpExportUtc       = true;
input bool     InpStrictOffsetLock = true;
input long     InpMaxReasonableRealVolume = 2000000000;
input bool     InpShowProgressComment = true;
input int      InpProgressLogStepPercent = 5;
input bool     InpMinimalLogging    = true; // when true, reduce console prints
input int      InpWorkerId          = 0;    // optional: worker id for external parallel runners (0-based)
input int      InpTotalWorkers      = 0;    // optional external sharding; 0/1 = this script processes every symbol
// Removed unsafe speed optimizations:
// - InpFastMode (always disabled)
// - InpSkipHarmonize (always false)
// - InpSmartHarmonize (always false)
// - InpFastHarmonize (always false)
// - InpBulkWriteCsv (always false)
// - InpBulkWriteBufferKb (not used)

// Safe constant overrides for removed inputs
const bool InpFastMode          = false;
const bool InpSkipHarmonize     = false;
const bool InpSmartHarmonize    = false;
const bool InpFastHarmonize     = false;
const bool InpBulkWriteCsv      = false;
const int  InpBulkWriteBufferKb = 64;   // not used, kept for reference

struct CsvBar
{
   datetime time;
   double open;
   double high;
   double low;
   double close;
   long tick_volume;
   int spread;
   long real_volume;
};

int    g_progress_total_steps = 0;
int    g_progress_done_steps  = 0;
ulong  g_progress_started_ms  = 0;
int    g_progress_last_bucket = -1;
string g_progress_detail      = "";
int    g_server_minus_gmt_sec = 0;

string TimeframeShortName(ENUM_TIMEFRAMES timeframe)
{
   switch(timeframe)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      default:         return EnumToString(timeframe);
   }
}

bool ParseTimeframe(const string raw_token, ENUM_TIMEFRAMES &timeframe)
{
   string token = raw_token;
   StringReplace(token, " ", "");
   StringToUpper(token);

   if(token == "M1")  { timeframe = PERIOD_M1;  return true; }
   if(token == "M5")  { timeframe = PERIOD_M5;  return true; }
   if(token == "M15") { timeframe = PERIOD_M15; return true; }
   if(token == "M30") { timeframe = PERIOD_M30; return true; }
   if(token == "H1")  { timeframe = PERIOD_H1;  return true; }
   if(token == "H4")  { timeframe = PERIOD_H4;  return true; }
   if(token == "D1")  { timeframe = PERIOD_D1;  return true; }

   return false;
}

bool IsIntradayTimeframe(const ENUM_TIMEFRAMES timeframe)
{
   return timeframe != PERIOD_D1;
}

bool IsRateValidForTimeframe(const MqlRates &rate, const ENUM_TIMEFRAMES timeframe)
{
   if(rate.time <= 0)
      return false;

   if(rate.high < rate.low)
      return false;

   if(rate.open <= 0 || rate.high <= 0 || rate.low <= 0 || rate.close <= 0)
      return false;

   if(rate.open > rate.high || rate.open < rate.low)
      return false;

   if(rate.close > rate.high || rate.close < rate.low)
      return false;

   return true;
}

bool PrepareSymbol(const string symbol)
{
   if(SymbolSelect(symbol, true))
      return true;
   if(!InpMinimalLogging) PrintFormat("Failed to select symbol %s. Error: %d", symbol, GetLastError());
   return false;
}

short ResolveDelimiter()
{
   if(StringLen(InpCsvDelimiter) > 0)
      return (short)StringGetCharacter(InpCsvDelimiter, 0);
   return ',';
}

string ResolveDelimiterText()
{
   if(StringLen(InpCsvDelimiter) > 0)
      return StringSubstr(InpCsvDelimiter, 0, 1);
   return ",";
}

int ResolveBulkWriteBufferChars()
{
   int kb = InpBulkWriteBufferKb;
   if(kb < 64)
      kb = 64;
   if(kb > 16384)
      kb = 16384;
   return kb * 1024;
}

string CsvHeaderLine()
{
   string d = ResolveDelimiterText();
   return "time" + d + "open" + d + "high" + d + "low" + d + "close" + d + "tick_volume" + d + "spread" + d + "real_volume";
}

int ResolveBaseOpenFlags()
{
   int flags = FILE_CSV | FILE_ANSI;
   if(InpUseCommonDir)
      flags |= FILE_COMMON;
   return flags;
}

int ResolveTextOpenFlags()
{
   int flags = FILE_TXT | FILE_ANSI;
   if(InpUseCommonDir)
      flags |= FILE_COMMON;
   return flags;
}

string CurrentExportTimeMode()
{
   return InpExportUtc ? "UTC" : "SERVER";
}

datetime ToExportTime(const datetime server_time)
{
   if(!InpExportUtc)
      return server_time;

   long shifted = (long)server_time - (long)g_server_minus_gmt_sec;
   if(shifted <= 0)
      return (datetime)0;
   return (datetime)shifted;
}

datetime ToServerTime(const datetime export_time)
{
   if(!InpExportUtc)
      return export_time;

   long shifted = (long)export_time + (long)g_server_minus_gmt_sec;
   if(shifted <= 0)
      return (datetime)0;
   return (datetime)shifted;
}

string TimeModeMarkerFileName(const string csv_file_name)
{
   return csv_file_name + ".tzmode";
}

string OffsetMarkerFileName(const string csv_file_name)
{
   return csv_file_name + ".tzoffset";
}

bool ReadTimeModeMarker(const string csv_file_name, string &mode)
{
   mode = "";
   string marker_name = TimeModeMarkerFileName(csv_file_name);
   int flags = ResolveTextOpenFlags() | FILE_READ;
   int handle = FileOpen(marker_name, flags);
   if(handle == INVALID_HANDLE)
      return false;

   string raw = FileReadString(handle);
   FileClose(handle);

   StringTrimLeft(raw);
   StringTrimRight(raw);
   StringToUpper(raw);
   if(raw == "UTC")
      mode = "UTC";
   else
      mode = "SERVER";

   return true;
}

bool WriteTimeModeMarker(const string csv_file_name)
{
   string marker_name = TimeModeMarkerFileName(csv_file_name);
   int flags = ResolveTextOpenFlags() | FILE_WRITE;
   int handle = FileOpen(marker_name, flags);
   if(handle == INVALID_HANDLE)
      return false;

   FileWriteString(handle, CurrentExportTimeMode());
   FileClose(handle);
   return true;
}

bool ReadOffsetMarker(const string csv_file_name, int &offset_sec)
{
   offset_sec = 0;
   string marker_name = OffsetMarkerFileName(csv_file_name);
   int flags = ResolveTextOpenFlags() | FILE_READ;
   int handle = FileOpen(marker_name, flags);
   if(handle == INVALID_HANDLE)
      return false;

   string raw = FileReadString(handle);
   FileClose(handle);

   StringTrimLeft(raw);
   StringTrimRight(raw);
   if(StringLen(raw) == 0)
      return false;

   long parsed = StringToInteger(raw);
   if(parsed < -86400 || parsed > 86400)
      return false;

   offset_sec = (int)parsed;
   return true;
}

bool WriteOffsetMarker(const string csv_file_name, const int offset_sec)
{
   string marker_name = OffsetMarkerFileName(csv_file_name);
   int flags = ResolveTextOpenFlags() | FILE_WRITE;
   int handle = FileOpen(marker_name, flags);
   if(handle == INVALID_HANDLE)
      return false;

   FileWriteString(handle, IntegerToString(offset_sec));
   FileClose(handle);
   return true;
}

string ResolveSymbol()
{
   if(StringLen(InpSymbol) > 0)
      return InpSymbol;
   return _Symbol;
}

string ResolveOutputPrefix(const string symbol)
{
   if(InpOutputPrefix == "")
      return symbol;

   return StringFormat("%s_%s", symbol, InpOutputPrefix);
}

string FormatDuration(const int total_seconds)
{
   int s = total_seconds;
   if(s < 0)
      s = 0;

   int h = s / 3600;
   int m = (s % 3600) / 60;
   int sec = s % 60;

   if(h > 0)
      return StringFormat("%dh %02dm %02ds", h, m, sec);

   return StringFormat("%02dm %02ds", m, sec);
}

string BuildProgressBar(const double percent)
{
   int width = 24;
   int filled = (int)MathRound((percent / 100.0) * width);
   if(filled < 0)
      filled = 0;
   if(filled > width)
      filled = width;

   string bar = "[";
   for(int i = 0; i < width; i++)
   {
      if(i < filled)
         bar += "#";
      else
         bar += "-";
   }
   bar += "]";
   return bar;
}

void InitProgress(const int total_steps)
{
   g_progress_total_steps = total_steps;
   if(g_progress_total_steps <= 0)
      g_progress_total_steps = 1;

   g_progress_done_steps = 0;
   g_progress_started_ms = GetTickCount64();
   g_progress_last_bucket = -1;
   g_progress_detail = "Starting...";
}

void UpdateProgressUi(const bool force_log)
{
   if(g_progress_total_steps <= 0)
      return;

   if(g_progress_done_steps < 0)
      g_progress_done_steps = 0;
   if(g_progress_done_steps > g_progress_total_steps)
      g_progress_done_steps = g_progress_total_steps;

   double percent = (100.0 * g_progress_done_steps) / g_progress_total_steps;
   ulong elapsed_ms = GetTickCount64() - g_progress_started_ms;
   int elapsed_s = (int)(elapsed_ms / 1000);
   int eta_s = 0;
   if(g_progress_done_steps > 0 && g_progress_done_steps < g_progress_total_steps)
   {
      double per_step = (double)elapsed_s / g_progress_done_steps;
      eta_s = (int)MathRound(per_step * (g_progress_total_steps - g_progress_done_steps));
   }

   string elapsed_txt = FormatDuration(elapsed_s);
   string eta_txt = (g_progress_done_steps >= g_progress_total_steps ? "00m 00s" : FormatDuration(eta_s));

   if(InpShowProgressComment)
   {
      string bar = BuildProgressBar(percent);
      string c = StringFormat(
         "AppendNewBars Progress\n%s %.1f%%\n%d/%d\nElapsed: %s | ETA: %s\n%s",
         bar,
         percent,
         g_progress_done_steps,
         g_progress_total_steps,
         elapsed_txt,
         eta_txt,
         g_progress_detail
      );
      Comment(c);
   }

   int step_pct = InpProgressLogStepPercent;
   if(step_pct <= 0)
      step_pct = 1;

   int bucket = (int)MathFloor(percent / step_pct);
   if(force_log || bucket > g_progress_last_bucket || g_progress_done_steps == g_progress_total_steps)
   {
      if(!InpMinimalLogging) PrintFormat(
         "Progress %d/%d (%.1f%%). elapsed=%s eta=%s detail=%s",
         g_progress_done_steps,
         g_progress_total_steps,
         percent,
         elapsed_txt,
         eta_txt,
         g_progress_detail
      );
      g_progress_last_bucket = bucket;
   }
}

void AdvanceProgress(const string detail, const bool force_log = false)
{
   g_progress_detail = detail;
   g_progress_done_steps++;
   UpdateProgressUi(force_log);
}

bool EnsureHistoryReady(const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   MqlRates probe[];
   // InpFastMode is always false -> use safe, thorough attempts
   int max_attempts = 20;
   int sleep_ms = 200;

   for(int i = 0; i < max_attempts; i++)
   {
      ResetLastError();
      int copied = CopyRates(symbol, timeframe, 0, 2, probe);
      if(copied > 0)
         return true;

      Sleep(sleep_ms);
   }

   return false;
}

datetime ResolveEarliestFromDate(const string symbol, const ENUM_TIMEFRAMES timeframe)
{
   // Deep probe: request a single bar from a very old date.
   // This is more reliable than SERIES_FIRSTDATE when terminal cache is temporarily short.
   datetime deep_from = D'1970.01.01 00:00';
   for(int attempt = 0; attempt < 25; attempt++)
   {
      MqlRates deep_probe[];
      ResetLastError();
      if(CopyRates(symbol, timeframe, deep_from, 1, deep_probe) > 0 && deep_probe[0].time > 0)
         return deep_probe[0].time;
      Sleep(120);
   }

   long first_date = SeriesInfoInteger(symbol, timeframe, SERIES_FIRSTDATE);
   if(first_date > 0)
      return (datetime)first_date;

   MqlRates probe[];
   if(CopyRates(symbol, timeframe, 0, 1, probe) > 0)
      return probe[0].time;

   return D'1970.01.01 00:00';
}

bool HasNormalizedHeader(const string file_name, const short delimiter, bool &normalized)
{
   normalized = false;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   if(FileIsEnding(handle))
   {
      FileClose(handle);
      return true;
   }

   string c0 = FileReadString(handle);
   string c1 = FileReadString(handle);
   string c2 = FileReadString(handle);
   string c3 = FileReadString(handle);
   string c4 = FileReadString(handle);
   string c5 = FileReadString(handle);
   string c6 = FileReadString(handle);
   string c7 = FileReadString(handle);
   FileClose(handle);

   if(c0 == "time" &&
      c1 == "open" &&
      c2 == "high" &&
      c3 == "low" &&
      c4 == "close" &&
      c5 == "tick_volume" &&
      c6 == "spread" &&
      c7 == "real_volume")
   {
      normalized = true;
   }

   return true;
}

bool DetectCoarseStartCadence(
   const string file_name,
   const short delimiter,
   const ENUM_TIMEFRAMES timeframe,
   bool &suspicious,
   int &sample_rows,
   int &unique_minutes,
   int &span_days
)
{
   suspicious = false;
   sample_rows = 0;
   unique_minutes = 0;
   span_days = 0;

   if(!IsIntradayTimeframe(timeframe))
      return true;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   datetime first_time = 0;
   datetime last_time  = 0;
   int minute_seen[1440];
   ArrayInitialize(minute_seen, 0);

   while(!FileIsEnding(handle) && sample_rows < 600)
   {
      string col_time = FileReadString(handle);
      for(int i = 0; i < 7 && !FileIsEnding(handle); i++)
         FileReadString(handle);

      if(col_time == "" || col_time == "time")
         continue;

      datetime parsed = StringToTime(col_time);
      if(parsed <= 0)
         continue;

      if(first_time == 0)
         first_time = parsed;
      last_time = parsed;

      MqlDateTime dt;
      TimeToStruct(parsed, dt);
      int minute_of_day = dt.hour * 60 + dt.min;
      if(minute_of_day >= 0 && minute_of_day < 1440 && minute_seen[minute_of_day] == 0)
      {
         minute_seen[minute_of_day] = 1;
         unique_minutes++;
      }

      sample_rows++;
   }

   FileClose(handle);

   if(first_time > 0 && last_time > first_time)
      span_days = (int)((last_time - first_time) / 86400);

   // Intraday file starts like D1/H1 if early rows have almost fixed intraday clock value.
   if(sample_rows >= 120 && span_days >= 30 && unique_minutes <= 3)
      suspicious = true;

   return true;
}

bool ReadLastTimestamp(const string file_name, const short delimiter, datetime &last_time)
{
   last_time = 0;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   string last_time_str = "";
   while(!FileIsEnding(handle))
   {
      string col_time = FileReadString(handle);
      for(int i = 0; i < 7 && !FileIsEnding(handle); i++)
         FileReadString(handle);

      if(col_time == "")
         continue;

      if(col_time != "time")
         last_time_str = col_time;
   }

   FileClose(handle);

   if(last_time_str == "")
      return true;

   datetime parsed = StringToTime(last_time_str);
   if(parsed > 0)
      last_time = parsed;

   return true;
}

bool ParseTimestampFromCsvLine(string line, datetime &parsed_time)
{
   parsed_time = 0;
   StringTrimLeft(line);
   StringTrimRight(line);

   if(StringLen(line) == 0)
      return false;

   if(StringFind(line, "time") == 0)
      return false;

   string delimiter_text = InpCsvDelimiter;
   if(StringLen(delimiter_text) == 0)
      delimiter_text = ",";
   else
      delimiter_text = StringSubstr(delimiter_text, 0, 1);

   int delimiter_pos = StringFind(line, delimiter_text);
   string time_text = line;
   if(delimiter_pos > 0)
      time_text = StringSubstr(line, 0, delimiter_pos);

   StringTrimLeft(time_text);
   StringTrimRight(time_text);
   datetime value = StringToTime(time_text);
   if(value <= 0)
      return false;

   parsed_time = value;
   return true;
}

bool ReadLastTimestampFast(const string file_name, const short delimiter, datetime &last_time)
{
   last_time = 0;

   int flags = FILE_READ | FILE_BIN | FILE_ANSI;
   if(InpUseCommonDir)
      flags |= FILE_COMMON;

   int handle = FileOpen(file_name, flags);
   if(handle == INVALID_HANDLE)
      return false;

   ulong file_size = FileSize(handle);
   if(file_size == 0)
   {
      FileClose(handle);
      return true;
   }

   int bytes_to_read = 65536;
   if(file_size < (ulong)bytes_to_read)
      bytes_to_read = (int)file_size;

   long start_pos = (long)file_size - bytes_to_read;
   if(!FileSeek(handle, start_pos, SEEK_SET))
   {
      FileClose(handle);
      return false;
   }

   string tail = FileReadString(handle, bytes_to_read);
   FileClose(handle);

   int pos = StringLen(tail) - 1;
   while(pos >= 0)
   {
      int ch = StringGetCharacter(tail, pos);
      if(ch == 10 || ch == 13 || ch == 0)
         pos--;
      else
         break;
   }

   while(pos >= 0)
   {
      int line_end = pos;
      while(pos >= 0)
      {
         int ch = StringGetCharacter(tail, pos);
         if(ch == 10 || ch == 13)
            break;
         pos--;
      }

      string line = StringSubstr(tail, pos + 1, line_end - pos);
      datetime parsed = 0;
      if(ParseTimestampFromCsvLine(line, parsed))
      {
         last_time = parsed;
         return true;
      }

      while(pos >= 0)
      {
         int ch = StringGetCharacter(tail, pos);
         if(ch == 10 || ch == 13)
            pos--;
         else
            break;
      }
   }

   return ReadLastTimestamp(file_name, delimiter, last_time);
}

bool ReadFirstTimestamp(const string file_name, const short delimiter, datetime &first_time)
{
   first_time = 0;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   while(!FileIsEnding(handle))
   {
      string col_time = FileReadString(handle);
      for(int i = 0; i < 7 && !FileIsEnding(handle); i++)
         FileReadString(handle);

      if(col_time == "")
         continue;

      if(col_time == "time")
         continue;

      datetime parsed = StringToTime(col_time);
      if(parsed > 0)
      {
         first_time = parsed;
         break;
      }
   }

   FileClose(handle);
   return true;
}

bool ReadCsvTimelineStats(
   const string file_name,
   const short delimiter,
   int &rows,
   datetime &first_time,
   datetime &last_time
)
{
   rows = 0;
   first_time = 0;
   last_time = 0;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   while(!FileIsEnding(handle))
   {
      string c0 = FileReadString(handle);
      for(int i = 0; i < 7 && !FileIsEnding(handle); i++)
         FileReadString(handle);

      if(c0 == "" || c0 == "time")
         continue;

      datetime t = StringToTime(c0);
      if(t <= 0)
         continue;

      if(first_time == 0)
         first_time = t;

      last_time = t;
      rows++;
   }

   FileClose(handle);
   return true;
}

datetime StartOfDay(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

datetime NextDayStart(const datetime day_start)
{
   return day_start + 86400;
}

bool IsCsvBarReasonableForStart(const CsvBar &bar, const ENUM_TIMEFRAMES timeframe)
{
   if(bar.time <= 0)
      return false;

   if(bar.high < bar.low)
      return false;

   // D1 is intentionally more permissive; user asked not to enforce intraday-style OHLC strictness on D1.
   if(!IsIntradayTimeframe(timeframe))
      return true;

   if(bar.open <= 0 || bar.high <= 0 || bar.low <= 0 || bar.close <= 0)
      return false;

   if(bar.open > bar.high || bar.open < bar.low)
      return false;

   if(bar.close > bar.high || bar.close < bar.low)
      return false;

   return true;
}

bool LoadCleanBarsFromCsv(
   const string file_name,
   const short delimiter,
   CsvBar &bars[],
   int &skipped_rows
)
{
   ArrayResize(bars, 0);
   skipped_rows = 0;

   int flags = ResolveBaseOpenFlags() | FILE_READ;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   while(!FileIsEnding(handle))
   {
      string c0 = FileReadString(handle);
      string c1 = FileReadString(handle);
      string c2 = FileReadString(handle);
      string c3 = FileReadString(handle);
      string c4 = FileReadString(handle);
      string c5 = FileReadString(handle);
      string c6 = FileReadString(handle);
      string c7 = FileReadString(handle);

      if(c0 == "" || c0 == "time")
         continue;

      CsvBar bar;
      bar.time        = StringToTime(c0);
      bar.open        = StringToDouble(c1);
      bar.high        = StringToDouble(c2);
      bar.low         = StringToDouble(c3);
      bar.close       = StringToDouble(c4);
      bar.tick_volume = (long)StringToInteger(c5);
      bar.spread      = (int)StringToInteger(c6);
      bar.real_volume = (long)StringToInteger(c7);

      // Do not drop rows one-by-one by OHLC rules; keep sequence and let reliable-start logic choose usable start.
      if(bar.time <= 0)
      {
         skipped_rows++;
         continue;
      }

      int n = ArraySize(bars);
      if(n > 0)
      {
         if(bar.time == bars[n - 1].time)
         {
            bars[n - 1] = bar;
            continue;
         }

         // Keep monotonic timeline; out-of-order old rows are treated as corrupted.
         if(bar.time < bars[n - 1].time)
         {
            skipped_rows++;
            continue;
         }
      }

      ArrayResize(bars, n + 1, 2048);
      bars[n] = bar;
   }

   FileClose(handle);
   return true;
}

int ComputeStableDensityStartPosCsv(const CsvBar &bars[], const ENUM_TIMEFRAMES timeframe)
{
   int n = ArraySize(bars);
   if(n <= 1 || !IsIntradayTimeframe(timeframe))
      return 0;

   datetime day_keys[];
   int day_counts[];
   ArrayResize(day_keys, 0);
   ArrayResize(day_counts, 0);

   datetime current_day = StartOfDay(bars[0].time);
   int current_count = 0;

   for(int i = 0; i < n; i++)
   {
      datetime d = StartOfDay(bars[i].time);
      if(d == current_day)
      {
         current_count++;
      }
      else
      {
         int m = ArraySize(day_keys);
         ArrayResize(day_keys, m + 1);
         ArrayResize(day_counts, m + 1);
         day_keys[m] = current_day;
         day_counts[m] = current_count;

         current_day = d;
         current_count = 1;
      }
   }

   int m = ArraySize(day_keys);
   ArrayResize(day_keys, m + 1);
   ArrayResize(day_counts, m + 1);
   day_keys[m] = current_day;
   day_counts[m] = current_count;

   int day_total = ArraySize(day_counts);
   if(day_total < 10)
      return 0;

   int tail_n = MathMin(60, day_total);
   int tail_counts[];
   ArrayResize(tail_counts, tail_n);
   for(int i = 0; i < tail_n; i++)
      tail_counts[i] = day_counts[day_total - tail_n + i];

   ArraySort(tail_counts);
   int recent_median = tail_counts[tail_n / 2];
   int threshold = (int)MathFloor(recent_median * 0.60);
   if(threshold < 10)
      threshold = 10;

   int run_need = 5;
   int run = 0;
   int run_start_day_idx = -1;

   for(int i = 0; i < day_total; i++)
   {
      if(day_counts[i] >= threshold)
      {
         if(run == 0)
            run_start_day_idx = i;
         run++;

         if(run >= run_need && run_start_day_idx >= 0)
         {
            datetime stable_day = day_keys[run_start_day_idx];
            datetime write_from_day = NextDayStart(stable_day);

            for(int k = 0; k < n; k++)
            {
               if(StartOfDay(bars[k].time) >= write_from_day)
                  return k;
            }

            // Fallback: if next day is unavailable, keep stable day itself.
            for(int k = 0; k < n; k++)
            {
               if(StartOfDay(bars[k].time) >= stable_day)
                  return k;
            }

            return 0;
         }
      }
      else
      {
         run = 0;
         run_start_day_idx = -1;
      }
   }

   return 0;
}

int FindReliableStartPositionCsv(const CsvBar &bars[], const ENUM_TIMEFRAMES timeframe)
{
   int count = ArraySize(bars);
   if(count <= 1 || !IsIntradayTimeframe(timeframe))
      return 0;

   int tf_seconds = PeriodSeconds(timeframe);
   if(tf_seconds <= 0)
      tf_seconds = 60;

   int min_long_pairs = 80;
   if((count - 1) < min_long_pairs)
      min_long_pairs = count - 1;

   if(min_long_pairs < 10)
      return 0;

   int density_pos = ComputeStableDensityStartPosCsv(bars, timeframe);
   if(density_pos < 0)
      density_pos = 0;
   if(density_pos >= count - 1)
      return 0;

   for(int pos = density_pos; pos < count - 1; pos++)
   {
      int considered = 0;
      int cadence_fine = 0;
      int value_fine = 0;
      int considered_early = 0;
      int cadence_fine_early = 0;

      for(int k = pos; k < count - 1 && considered < 240; k++)
      {
         int delta = (int)(bars[k + 1].time - bars[k].time);
         if(delta <= 0)
            continue;

         considered++;
         bool cadence_ok = (delta <= tf_seconds * 3);
         if(cadence_ok)
            cadence_fine++;
         if(considered <= 60)
         {
            considered_early++;
            if(cadence_ok)
               cadence_fine_early++;
         }

         if(
            IsCsvBarReasonableForStart(bars[k], timeframe) &&
            IsCsvBarReasonableForStart(bars[k + 1], timeframe)
         )
            value_fine++;
      }

      if(
         considered >= min_long_pairs &&
         (cadence_fine * 100) >= (considered * 90) &&
         (value_fine   * 100) >= (considered * 80) &&
         (considered_early > 0 && (cadence_fine_early * 100) >= (considered_early * 85))
      )
         return pos;
   }

   for(int pos = density_pos; pos < count - 1; pos++)
   {
      int considered = 0;
      int cadence_fine = 0;
      int value_fine = 0;
      int considered_early = 0;
      int cadence_fine_early = 0;

      for(int k = pos; k < count - 1 && considered < 40; k++)
      {
         int delta = (int)(bars[k + 1].time - bars[k].time);
         if(delta <= 0)
            continue;

         considered++;
         bool cadence_ok = (delta <= tf_seconds * 3);
         if(cadence_ok)
            cadence_fine++;
         if(considered <= 20)
         {
            considered_early++;
            if(cadence_ok)
               cadence_fine_early++;
         }

         if(
            IsCsvBarReasonableForStart(bars[k], timeframe) &&
            IsCsvBarReasonableForStart(bars[k + 1], timeframe)
         )
            value_fine++;
      }

      if(
         considered >= 16 &&
         (cadence_fine * 100) >= (considered * 85) &&
         (value_fine   * 100) >= (considered * 75) &&
         (considered_early > 0 && (cadence_fine_early * 100) >= (considered_early * 80))
      )
         return pos;
   }

   return density_pos;
}

void TrimBarsFromIndex(CsvBar &bars[], const int start_pos)
{
   int n = ArraySize(bars);
   if(start_pos <= 0 || start_pos >= n)
      return;

   int new_size = n - start_pos;
   for(int i = 0; i < new_size; i++)
      bars[i] = bars[i + start_pos];

   ArrayResize(bars, new_size);
}

void TrimBarsBeforeDate(CsvBar &bars[], const datetime min_day)
{
   int n = ArraySize(bars);
   if(n <= 0)
      return;

   int start_pos = 0;
   while(start_pos < n && bars[start_pos].time < min_day)
      start_pos++;

   TrimBarsFromIndex(bars, start_pos);
}

bool WriteBarsToCsv(
   const string file_name,
   const short delimiter,
   const CsvBar &bars[],
   const int digits
)
{
   // InpBulkWriteCsv is always false, so use safe FILE_CSV mode
   int flags = ResolveBaseOpenFlags() | FILE_WRITE;
   int handle = FileOpen(file_name, flags, delimiter);
   if(handle == INVALID_HANDLE)
      return false;

   FileWrite(handle, "time", "open", "high", "low", "close", "tick_volume", "spread", "real_volume");

   for(int i = 0; i < ArraySize(bars); i++)
   {
      FileWrite(
         handle,
         TimeToString(bars[i].time, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
         DoubleToString(bars[i].open,  digits),
         DoubleToString(bars[i].high,  digits),
         DoubleToString(bars[i].low,   digits),
         DoubleToString(bars[i].close, digits),
         bars[i].tick_volume,
         bars[i].spread,
         bars[i].real_volume
      );
   }

   FileClose(handle);
   return true;
}

void HarmonizeSymbolFiles(
   const string symbol,
   const string output_prefix,
   const ENUM_TIMEFRAMES &timeframes[]
)
{
   short delimiter = ResolveDelimiter();
   datetime common_start_day = 0;
   bool any_loaded = false;

   for(int i = 0; i < ArraySize(timeframes); i++)
   {
      string tf_name = TimeframeShortName(timeframes[i]);
      g_progress_detail = StringFormat("%s harmonize scan %s", symbol, tf_name);
      UpdateProgressUi(false);
      string file_name = StringFormat("%s_%s.csv", output_prefix, tf_name);
      if(!FileIsExist(file_name, InpUseCommonDir ? FILE_COMMON : 0))
         continue;

      CsvBar bars[];
      int skipped_rows = 0;
      if(!LoadCleanBarsFromCsv(file_name, delimiter, bars, skipped_rows))
      {
         if(!InpMinimalLogging) PrintFormat("Harmonize read failed for %s (%s): %s", symbol, tf_name, file_name);
         continue;
      }

      if(ArraySize(bars) <= 0)
         continue;

      int start_pos = FindReliableStartPositionCsv(bars, timeframes[i]);
      if(start_pos > 0)
         TrimBarsFromIndex(bars, start_pos);

      if(ArraySize(bars) <= 0)
         continue;

      datetime first_day = StartOfDay(bars[0].time);
      if(!any_loaded || first_day > common_start_day)
         common_start_day = first_day;

      any_loaded = true;
   }

   if(!any_loaded)
      return;

   if(!InpMinimalLogging) PrintFormat(
      "Harmonize anchor for %s => common_start_day=%s",
      symbol,
      TimeToString(common_start_day, TIME_DATE)
   );

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits <= 0)
      digits = 5;

   for(int i = 0; i < ArraySize(timeframes); i++)
   {
      string tf_name = TimeframeShortName(timeframes[i]);
      g_progress_detail = StringFormat("%s harmonize write %s", symbol, tf_name);
      UpdateProgressUi(false);
      string file_name = StringFormat("%s_%s.csv", output_prefix, tf_name);
      if(!FileIsExist(file_name, InpUseCommonDir ? FILE_COMMON : 0))
         continue;

      CsvBar bars[];
      int skipped_rows = 0;
      if(!LoadCleanBarsFromCsv(file_name, delimiter, bars, skipped_rows))
      {
         if(!InpMinimalLogging) PrintFormat("Harmonize reread failed for %s (%s): %s", symbol, tf_name, file_name);
         continue;
      }

      if(ArraySize(bars) <= 0)
         continue;

      int start_pos = FindReliableStartPositionCsv(bars, timeframes[i]);
      if(start_pos > 0)
         TrimBarsFromIndex(bars, start_pos);

      TrimBarsBeforeDate(bars, common_start_day);
      if(ArraySize(bars) <= 0)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Harmonize produced empty set for %s (%s). common_start=%s",
            symbol,
            tf_name,
            TimeToString(common_start_day, TIME_DATE)
         );
         continue;
      }

      if(!WriteBarsToCsv(file_name, delimiter, bars, digits))
      {
         if(!InpMinimalLogging) PrintFormat("Harmonize write failed for %s (%s): %s", symbol, tf_name, file_name);
         continue;
      }

      if(!InpMinimalLogging) PrintFormat(
         "Harmonized %s (%s). start=%s rows=%d skipped_rows=%d",
         symbol,
         tf_name,
         TimeToString(StartOfDay(bars[0].time), TIME_DATE),
         ArraySize(bars),
         skipped_rows
      );
   }
}

bool HarmonizeSymbolFilesFast(
   const string symbol,
   const string output_prefix,
   const ENUM_TIMEFRAMES &timeframes[]
)
{
   // This function is kept for compatibility but will never be called because InpFastHarmonize is false.
   // Safe fallback: simply call the full harmonization.
   HarmonizeSymbolFiles(symbol, output_prefix, timeframes);
   return true;
}

bool BuildTimeframes(ENUM_TIMEFRAMES &timeframes[])
{
   ArrayResize(timeframes, 0);

   string raw_parts[];
   int part_count = StringSplit(InpTimeframes, ',', raw_parts);
   if(part_count <= 0)
      return false;

   for(int i = 0; i < part_count; i++)
   {
      ENUM_TIMEFRAMES timeframe;
      if(!ParseTimeframe(raw_parts[i], timeframe))
      {
         if(!InpMinimalLogging) PrintFormat("Unknown timeframe token skipped: %s", raw_parts[i]);
         continue;
      }

      int new_size = ArraySize(timeframes) + 1;
      ArrayResize(timeframes, new_size);
      timeframes[new_size - 1] = timeframe;
   }

   return ArraySize(timeframes) > 0;
}

int FindReliableIntradayStartPosition(
   const MqlRates &rates[],
   const int &ordered_indices[],
   const ENUM_TIMEFRAMES timeframe
)
{
   int count = ArraySize(ordered_indices);
   if(!IsIntradayTimeframe(timeframe) || count <= 1)
      return 0;

   int tf_seconds = PeriodSeconds(timeframe);
   if(tf_seconds <= 0)
      tf_seconds = 60;

   int min_long_pairs = 80;
   if((count - 1) < min_long_pairs)
      min_long_pairs = count - 1;

   if(min_long_pairs < 10)
      return 0;

   int density_pos = 0;
   {
      datetime day_keys[];
      int day_counts[];
      ArrayResize(day_keys, 0);
      ArrayResize(day_counts, 0);

      datetime current_day = StartOfDay(rates[ordered_indices[0]].time);
      int current_count = 0;

      for(int i = 0; i < count; i++)
      {
         datetime d = StartOfDay(rates[ordered_indices[i]].time);
         if(d == current_day)
         {
            current_count++;
         }
         else
         {
            int m = ArraySize(day_keys);
            ArrayResize(day_keys, m + 1);
            ArrayResize(day_counts, m + 1);
            day_keys[m] = current_day;
            day_counts[m] = current_count;

            current_day = d;
            current_count = 1;
         }
      }

      int m = ArraySize(day_keys);
      ArrayResize(day_keys, m + 1);
      ArrayResize(day_counts, m + 1);
      day_keys[m] = current_day;
      day_counts[m] = current_count;

      int day_total = ArraySize(day_counts);
      if(day_total >= 10)
      {
         int tail_n = MathMin(60, day_total);
         int tail_counts[];
         ArrayResize(tail_counts, tail_n);
         for(int i = 0; i < tail_n; i++)
            tail_counts[i] = day_counts[day_total - tail_n + i];

         ArraySort(tail_counts);
         int recent_median = tail_counts[tail_n / 2];
         int threshold = (int)MathFloor(recent_median * 0.60);
         if(threshold < 10)
            threshold = 10;

         int run_need = 5;
         int run = 0;
         int run_start_day_idx = -1;
         datetime stable_day = 0;
         for(int i = 0; i < day_total; i++)
         {
            if(day_counts[i] >= threshold)
            {
               if(run == 0)
                  run_start_day_idx = i;
               run++;
               if(run >= run_need && run_start_day_idx >= 0)
               {
                  stable_day = day_keys[run_start_day_idx];
                  break;
               }
            }
            else
            {
               run = 0;
               run_start_day_idx = -1;
            }
         }

         if(stable_day > 0)
         {
            datetime write_from_day = NextDayStart(stable_day);

            for(int i = 0; i < count; i++)
            {
               if(StartOfDay(rates[ordered_indices[i]].time) >= write_from_day)
               {
                  density_pos = i;
                  break;
               }
            }

            if(density_pos == 0)
            {
               for(int i = 0; i < count; i++)
               {
                  if(StartOfDay(rates[ordered_indices[i]].time) >= stable_day)
                  {
                     density_pos = i;
                     break;
                  }
               }
            }
         }
      }
   }

   for(int pos = density_pos; pos < count - 1; pos++)
   {
      int considered = 0;
      int fine = 0;
      int considered_early = 0;
      int fine_early = 0;

      for(int k = pos; k < count - 1 && considered < 240; k++)
      {
         int idx_a = ordered_indices[k];
         int idx_b = ordered_indices[k + 1];
         int delta = (int)(rates[idx_b].time - rates[idx_a].time);
         if(delta <= 0)
            continue;

         considered++;
         bool cadence_ok = (delta <= tf_seconds * 3);
         if(cadence_ok)
            fine++;
         if(considered <= 60)
         {
            considered_early++;
            if(cadence_ok)
               fine_early++;
         }
      }

      if(
         considered >= min_long_pairs &&
         (fine * 100) >= (considered * 90) &&
         (considered_early > 0 && (fine_early * 100) >= (considered_early * 85))
      )
         return pos;
   }

   for(int pos = density_pos; pos < count - 1; pos++)
   {
      int considered = 0;
      int fine = 0;
      int considered_early = 0;
      int fine_early = 0;

      for(int k = pos; k < count - 1 && considered < 40; k++)
      {
         int idx_a = ordered_indices[k];
         int idx_b = ordered_indices[k + 1];
         int delta = (int)(rates[idx_b].time - rates[idx_a].time);
         if(delta <= 0)
            continue;

         considered++;
         bool cadence_ok = (delta <= tf_seconds * 3);
         if(cadence_ok)
            fine++;
         if(considered <= 20)
         {
            considered_early++;
            if(cadence_ok)
               fine_early++;
         }
      }

      if(
         considered >= 16 &&
         (fine * 100) >= (considered * 85) &&
         (considered_early > 0 && (fine_early * 100) >= (considered_early * 80))
      )
         return pos;
   }

   return density_pos;
}

bool AppendRatesToCsv(
   const string symbol,
   const ENUM_TIMEFRAMES timeframe,
   const datetime last_time,
   const datetime to_date,
   const string file_name,
   const bool rebuild_file
)
{
   if(!rebuild_file && last_time > 0)
   {
      datetime export_to = ToExportTime(to_date);
      int tf_seconds = PeriodSeconds(timeframe);
      if(tf_seconds <= 0)
         tf_seconds = 1;

      if(export_to > 0 && (last_time + (datetime)tf_seconds) > export_to)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Already current for %s (%s). last_time=%s",
            symbol,
            TimeframeShortName(timeframe),
            TimeToString(last_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS)
         );
         return true;
      }
   }

   if(!EnsureHistoryReady(symbol, timeframe))
   {
      if(!InpMinimalLogging) PrintFormat(
         "History is not ready for %s (%s). Open this symbol/timeframe once in Market Watch/Chart and try again.",
         symbol,
         TimeframeShortName(timeframe)
      );
      return false;
   }

   datetime request_from = D'1970.01.01 00:00';
   if(!rebuild_file && last_time > 0)
   {
      datetime server_last_time = ToServerTime(last_time);
      if(server_last_time > 0)
         request_from = server_last_time + 1;
   }

   ResetLastError();
   MqlRates rates[];
   int copied = CopyRates(symbol, timeframe, request_from, to_date, rates);
   if(copied <= 0)
   {
      int err = GetLastError();
      if(err == 0)
      {
         if(!InpMinimalLogging) PrintFormat(
            "No new bars for %s (%s). from=%s to=%s",
            symbol,
            TimeframeShortName(timeframe),
            TimeToString(request_from, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
            TimeToString(to_date, TIME_DATE | TIME_MINUTES | TIME_SECONDS)
         );
         return true;
      }

      if(!InpMinimalLogging) PrintFormat(
         "No bars fetched for %s (%s). Error: %d from=%s to=%s",
         symbol,
         TimeframeShortName(timeframe),
         err,
         TimeToString(request_from, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
         TimeToString(to_date, TIME_DATE | TIME_MINUTES | TIME_SECONDS)
      );
      return false;
   }

   short delimiter = ResolveDelimiter();
   int base_flags = ResolveBaseOpenFlags();
   bool file_exists = FileIsExist(file_name, InpUseCommonDir ? FILE_COMMON : 0);

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits <= 0)
      digits = 5;

   int old_rows = 0;
   datetime old_first_time = 0;
   datetime old_last_time = 0;
   bool old_stats_read = false;
   if(file_exists && rebuild_file)
      old_stats_read = ReadCsvTimelineStats(file_name, delimiter, old_rows, old_first_time, old_last_time);

   int start_index = 0;
   int end_index   = copied;
   int step        = 1;

   if(copied > 1 && rates[0].time > rates[copied - 1].time)
   {
      start_index = copied - 1;
      end_index   = -1;
      step        = -1;
   }

   int skipped_invalid = 0;
   int ordered_indices[];
   ArrayResize(ordered_indices, copied);
   int eligible_count = 0;

   for(int i = start_index; i != end_index; i += step)
   {
      if(rates[i].time > to_date)
         continue;

      datetime rate_export_time = ToExportTime(rates[i].time);
      if(!rebuild_file && last_time > 0 && rate_export_time <= last_time)
         continue;

      if(!IsRateValidForTimeframe(rates[i], timeframe))
      {
         skipped_invalid++;
         continue;
      }

      ordered_indices[eligible_count] = i;
      eligible_count++;
   }

   if(eligible_count <= 0)
   {
      PrintFormat(
         "No bars written for %s (%s). last_time=%s",
         symbol,
         TimeframeShortName(timeframe),
         (last_time > 0 ? TimeToString(last_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS) : "n/a")
      );
      return true;
   }

   if(eligible_count < copied)
      ArrayResize(ordered_indices, eligible_count);

   int first_write_pos = 0;
   if(
      IsIntradayTimeframe(timeframe) &&
      (rebuild_file || last_time <= 0)
   )
   {
      first_write_pos = FindReliableIntradayStartPosition(rates, ordered_indices, timeframe);
      if(first_write_pos > 0)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Auto-detected reliable start for %s (%s). Skipping %d early bars with coarse cadence.",
            symbol,
            TimeframeShortName(timeframe),
            first_write_pos
         );
      }
   }

    int planned_written = eligible_count - first_write_pos;
      if(planned_written <= 0)
      {
         if(!InpMinimalLogging) PrintFormat(
             "No bars written for %s (%s). last_time=%s",
             symbol,
             TimeframeShortName(timeframe),
             (last_time > 0 ? TimeToString(last_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS) : "n/a")
         );
         return true;
      }

    datetime planned_first_time = ToExportTime(rates[ordered_indices[first_write_pos]].time);
    if(
       rebuild_file &&
       file_exists &&
       old_stats_read &&
       old_rows > 0 &&
       old_first_time > 0 &&
       IsIntradayTimeframe(timeframe)
    )
    {
      int tf_seconds = PeriodSeconds(timeframe);
      if(tf_seconds <= 0)
         tf_seconds = 60;

      bool new_is_much_shorter = (planned_written * 100 < old_rows * 70);
      bool new_starts_far_later = (planned_first_time > (old_first_time + (datetime)(tf_seconds * 500)));
      bool suspicious_intraday_shrink = (planned_written < 5000 && old_rows > 50000);

      if((new_is_much_shorter && new_starts_far_later) || suspicious_intraday_shrink)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Rebuild rejected for %s (%s). Keeping existing file due to suspicious shrink. old_rows=%d new_rows=%d old_first=%s new_first=%s old_last=%s",
            symbol,
            TimeframeShortName(timeframe),
            old_rows,
            planned_written,
            TimeToString(old_first_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
            TimeToString(planned_first_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
            TimeToString(old_last_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS)
         );
         return true;
      }
    }

   if(rebuild_file && file_exists)
   {
      FileDelete(file_name, InpUseCommonDir ? FILE_COMMON : 0);
      file_exists = FileIsExist(file_name, InpUseCommonDir ? FILE_COMMON : 0);
   }

   // InpBulkWriteCsv is always false, so always use safe FILE_CSV mode
   int open_flags = base_flags;

   int handle = INVALID_HANDLE;
   if(file_exists && !rebuild_file)
      handle = FileOpen(file_name, open_flags | FILE_READ | FILE_WRITE, delimiter);
   else
      handle = FileOpen(file_name, open_flags | FILE_WRITE, delimiter);

   if(handle == INVALID_HANDLE)
   {
      if(!InpMinimalLogging) PrintFormat("Failed to open file %s. Error: %d", file_name, GetLastError());
      return false;
   }

   int written = 0;
   // Safe, non-buffered CSV writing
   if(file_exists && !rebuild_file)
      FileSeek(handle, 0, SEEK_END);
   else
      FileWrite(handle, "time", "open", "high", "low", "close", "tick_volume", "spread", "real_volume");

   for(int pos = first_write_pos; pos < eligible_count; pos++)
   {
      int idx = ordered_indices[pos];

      FileWrite(
         handle,
         TimeToString(ToExportTime(rates[idx].time), TIME_DATE | TIME_MINUTES | TIME_SECONDS),
         DoubleToString(rates[idx].open,  digits),
         DoubleToString(rates[idx].high,  digits),
         DoubleToString(rates[idx].low,   digits),
         DoubleToString(rates[idx].close, digits),
         rates[idx].tick_volume,
         rates[idx].spread,
         rates[idx].real_volume
      );
      written++;
   }

   FileClose(handle);
   if(!WriteTimeModeMarker(file_name))
      if(!InpMinimalLogging) PrintFormat("Warning: failed to write time mode marker for %s", file_name);
   if(!WriteOffsetMarker(file_name, g_server_minus_gmt_sec))
      if(!InpMinimalLogging) PrintFormat("Warning: failed to write offset marker for %s", file_name);

   if(skipped_invalid > 0)
   {
      if(!InpMinimalLogging) PrintFormat(
         "Skipped %d suspicious bars for %s (%s) while writing %s",
         skipped_invalid,
         symbol,
         TimeframeShortName(timeframe),
         file_name
      );
   }

   if(written == 0)
   {
      if(!InpMinimalLogging) PrintFormat(
         "No bars written for %s (%s). last_time=%s",
         symbol,
         TimeframeShortName(timeframe),
         (last_time > 0 ? TimeToString(last_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS) : "n/a")
      );
      return true;
   }

   if(!InpMinimalLogging) PrintFormat(
      "Appended %d bars to %s for %s (%s).",
      written,
      file_name,
      symbol,
      TimeframeShortName(timeframe)
   );

   return true;
}

bool UpdateSymbol(
   const string symbol,
   const ENUM_TIMEFRAMES &timeframes[],
   const datetime global_to,
   int &success_count,
   int &processed_count,
   const bool progress_enabled
)
{
   if(!PrepareSymbol(symbol))
      return false;

   string output_prefix = ResolveOutputPrefix(symbol);
   bool symbol_needs_harmonize = false;

   for(int i = 0; i < ArraySize(timeframes); i++)
   {
      processed_count++;

      string tf_name = TimeframeShortName(timeframes[i]);
      string file_name = StringFormat("%s_%s.csv", output_prefix, tf_name);
      bool file_exists = FileIsExist(file_name, InpUseCommonDir ? FILE_COMMON : 0);
      short delimiter = ResolveDelimiter();

      datetime last_time = 0;
      if(file_exists && !ReadLastTimestampFast(file_name, delimiter, last_time))
         ReadLastTimestamp(file_name, delimiter, last_time);

      datetime first_time = 0;
      datetime earliest_available_export = 0;
      // InpFastMode is always false -> deep_repair_checks always true when file exists
      bool deep_repair_checks = (file_exists);
      if(deep_repair_checks)
      {
         ReadFirstTimestamp(file_name, delimiter, first_time);
         datetime earliest_available = ResolveEarliestFromDate(symbol, timeframes[i]);
         earliest_available_export = ToExportTime(earliest_available);
      }

      bool rebuild_file = false;
      bool rebuild_due_to_gap_missing_older = false;
      bool rebuild_due_to_header = false;
      bool rebuild_due_to_cadence = false;
      bool rebuild_due_to_forced_start = false;
      bool rebuild_due_to_time_mode = false;
      bool rebuild_due_to_offset_change = false;
      bool rebuild_due_to_empty_file = false;
      int cadence_sample_rows = 0;
      int cadence_unique_minutes = 0;
      int cadence_span_days = 0;

      if(file_exists && last_time <= 0)
      {
         rebuild_file = true;
         rebuild_due_to_empty_file = true;
      }

      if(file_exists)
      {
         string marker_mode = "";
         bool marker_exists = ReadTimeModeMarker(file_name, marker_mode);
         string active_mode = CurrentExportTimeMode();
         if(!marker_exists || marker_mode != active_mode)
         {
            rebuild_file = true;
            rebuild_due_to_time_mode = true;
         }
      }

      if(file_exists)
      {
         int marker_offset_sec = 0;
         bool offset_marker_exists = ReadOffsetMarker(file_name, marker_offset_sec);
         if(offset_marker_exists && marker_offset_sec != g_server_minus_gmt_sec)
         {
            if(InpStrictOffsetLock)
            {
               if(!InpMinimalLogging) PrintFormat(
                  "Offset lock triggered for %s (%s). marker_offset_sec=%d current_offset_sec=%d. "
                  "Abort to prevent timezone drift. Disable InpStrictOffsetLock to allow rebuild.",
                  symbol,
                  tf_name,
                  marker_offset_sec,
                  g_server_minus_gmt_sec
               );
               return false;
            }
            rebuild_file = true;
            rebuild_due_to_offset_change = true;
         }
      }

      if(file_exists && InpForceRebuildFromStart)
      {
         rebuild_file = true;
         rebuild_due_to_forced_start = true;
      }

      if(file_exists)
      {
         bool normalized_header = true;
         if(!HasNormalizedHeader(file_name, delimiter, normalized_header))
         {
            if(!InpMinimalLogging) PrintFormat("Could not inspect CSV header for %s (%s): %s", symbol, tf_name, file_name);
         }
         else if(!normalized_header)
         {
            rebuild_file = true;
            rebuild_due_to_header = true;
         }
      }

      if(deep_repair_checks)
      {
         bool cadence_suspicious = false;
         if(!DetectCoarseStartCadence(
            file_name,
            delimiter,
            timeframes[i],
            cadence_suspicious,
            cadence_sample_rows,
            cadence_unique_minutes,
            cadence_span_days
         ))
         {
            if(!InpMinimalLogging) PrintFormat("Could not inspect CSV cadence for %s (%s): %s", symbol, tf_name, file_name);
         }
         else if(cadence_suspicious)
         {
            rebuild_file = true;
            rebuild_due_to_cadence = true;
         }
      }

      if(deep_repair_checks && first_time > 0 && earliest_available_export > 0)
      {
         int sec = PeriodSeconds(timeframes[i]);
         if(sec <= 0)
            sec = 1;

         // If CSV starts later than what terminal currently has, rebuild to backfill older bars.
         if((earliest_available_export + sec) < first_time)
         {
            rebuild_file = true;
            rebuild_due_to_gap_missing_older = true;
         }

      }

      datetime to_date = global_to;
      if(InpClosedBarsOnly)
      {
         int seconds = PeriodSeconds(timeframes[i]);
         if(seconds > 0)
            to_date -= seconds;
      }

      if(rebuild_due_to_forced_start)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Rebuilding %s (%s) from earliest available history for file %s",
            symbol,
            tf_name,
            file_name
         );
      }

      if(rebuild_due_to_gap_missing_older)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected missing older history for %s (%s). Rebuilding file %s. earliest=%s csv_first=%s",
            symbol,
            tf_name,
            file_name,
            TimeToString(earliest_available_export, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
            TimeToString(first_time, TIME_DATE | TIME_MINUTES | TIME_SECONDS)
         );
      }

      if(rebuild_due_to_time_mode)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected time mode mismatch for %s (%s). Rebuilding file %s with mode=%s",
            symbol,
            tf_name,
            file_name,
            CurrentExportTimeMode()
         );
      }

      if(rebuild_due_to_offset_change)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected offset mismatch for %s (%s). Rebuilding file %s with current_offset_sec=%d",
            symbol,
            tf_name,
            file_name,
            g_server_minus_gmt_sec
         );
      }

      if(rebuild_due_to_header)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected non-standard header for %s (%s). Rebuilding file %s with normalized schema.",
            symbol,
            tf_name,
            file_name
         );
      }

      if(rebuild_due_to_empty_file)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected empty or unreadable CSV timeline for %s (%s). Rebuilding file %s.",
            symbol,
            tf_name,
            file_name
         );
      }

      if(rebuild_due_to_cadence)
      {
         if(!InpMinimalLogging) PrintFormat(
            "Detected suspicious intraday cadence at file start for %s (%s). Rebuilding file %s. sample_rows=%d unique_minutes=%d span_days=%d",
            symbol,
            tf_name,
            file_name,
            cadence_sample_rows,
            cadence_unique_minutes,
            cadence_span_days
         );
      }

      if(!file_exists || rebuild_file)
         symbol_needs_harmonize = true;

      if(AppendRatesToCsv(symbol, timeframes[i], last_time, to_date, file_name, rebuild_file))
         success_count++;

      if(progress_enabled)
         AdvanceProgress(StringFormat("%s %s done", symbol, tf_name), false);
   }

   // Harmonization always performed (skip flags are false)
   bool should_harmonize = (ArraySize(timeframes) > 1);
   if(should_harmonize)
   {
      // InpFastHarmonize and InpSmartHarmonize are false, so always use full harmonization
      HarmonizeSymbolFiles(symbol, output_prefix, timeframes);
      if(progress_enabled)
         AdvanceProgress(StringFormat("%s harmonize done", symbol), true);
   }
   else
   {
      if(progress_enabled)
         AdvanceProgress(StringFormat("%s harmonize skipped (single timeframe)", symbol), true);
   }

   return true;
}

void OnStart()
{
   ENUM_TIMEFRAMES timeframes[];
   if(!BuildTimeframes(timeframes))
   {
      Print("InpTimeframes is empty. Example: M1,M5,M15,H1,H4,D1");
      return;
   }

   datetime terminal_now = TimeCurrent();
   datetime server_now = TimeTradeServer();
   datetime gmt_now = TimeGMT();
   g_server_minus_gmt_sec = (int)(server_now - gmt_now);
   double server_minus_gmt_hours = (double)g_server_minus_gmt_sec / 3600.0;
   if(!InpMinimalLogging) PrintFormat(
      "Time diagnostics: terminal=%s server=%s gmt=%s server_minus_gmt_sec=%I64d (%.2f h)",
      TimeToString(terminal_now, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
      TimeToString(server_now, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
      TimeToString(gmt_now, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
      (long)g_server_minus_gmt_sec,
      server_minus_gmt_hours
   );
   if(!InpMinimalLogging) PrintFormat(
      "Export time mode: %s (CSV 'time' column uses %s clock)",
      CurrentExportTimeMode(),
      CurrentExportTimeMode()
   );

   datetime global_to = TimeCurrent();

   int total_success_count = 0;
   int total_processed_count = 0;
   int symbol_count = 0;
   bool progress_enabled = true;

   int worker_count = 1;
   if(InpTotalWorkers > 1)
      worker_count = InpTotalWorkers;

   int worker_id = InpWorkerId;
   if(worker_id < 0)
      worker_id = 0;
   if(worker_count > 1 && worker_id >= worker_count)
      worker_id = worker_count - 1;

   string raw_symbols[];
   int raw_count = 0;
   if(InpAllLoadedSymbols)
   {
      int total = (int)SymbolsTotal(true);

      for(int i = 0; i < total; i++)
      {
         string sname = SymbolName(i, true);
         StringTrimLeft(sname);
         StringTrimRight(sname);
         if(StringLen(sname) == 0)
            continue;
         int n = ArraySize(raw_symbols);
         ArrayResize(raw_symbols, n + 1, 256);
         raw_symbols[n] = sname;
      }
      raw_count = ArraySize(raw_symbols);
      if(raw_count <= 0)
         raw_count = StringSplit(ResolveSymbol(), ',', raw_symbols);
   }
   else
   {
      raw_count = StringSplit(ResolveSymbol(), ',', raw_symbols);
   }

   if(raw_count <= 0)
   {
      PrintFormat("No symbols to process. Check InpAllLoadedSymbols, InpSymbol or your Market Watch symbol list.");
      return;
   }

   int symbols_to_process[];
   ArrayResize(symbols_to_process, 0);
   for(int si = 0; si < raw_count; si++)
   {
      string sname = raw_symbols[si];
      StringTrimLeft(sname);
      StringTrimRight(sname);
      if(StringLen(sname) == 0)
         continue;
      // worker sharding
      if(worker_count > 1)
      {
         if((si % worker_count) != worker_id)
            continue;
      }
      int n = ArraySize(symbols_to_process);
      ArrayResize(symbols_to_process, n + 1, 256);
      symbols_to_process[n] = si; // store index into raw_symbols
   }

   int symbol_list_count = ArraySize(symbols_to_process);
   if(symbol_list_count <= 0)
   {
      if(!InpMinimalLogging) Print("No symbols to process after sharding. Check InpSymbol and worker settings.");
      return;
   }

   int planned_steps = symbol_list_count * ArraySize(timeframes) + 1;
   InitProgress(planned_steps);
   UpdateProgressUi(true);

   if(!InpMinimalLogging) PrintFormat("Append start. Symbols=%d Timeframes=%d Worker=%d/%d", symbol_list_count, ArraySize(timeframes), worker_id, worker_count);

   int total_succ = 0;
   int total_proc = 0;
   for(int si = 0; si < symbol_list_count; si++)
   {
      string target_symbol = raw_symbols[symbols_to_process[si]];
      StringTrimLeft(target_symbol);
      StringTrimRight(target_symbol);

      int symbol_success = 0;
      int symbol_processed = 0;
      bool ok = UpdateSymbol(target_symbol, timeframes, global_to, symbol_success, symbol_processed, progress_enabled);
      if(ok)
         symbol_count++;
      else
      {
         for(int s = 0; s < ArraySize(timeframes) + 1; s++)
            AdvanceProgress(StringFormat("%s skipped", target_symbol), (s == ArraySize(timeframes)));
      }

      total_succ += symbol_success;
      total_proc += symbol_processed;
   }

   total_success_count = total_succ;
   total_processed_count = total_proc;

   if(!InpMinimalLogging) PrintFormat(
      "Append update complete. Symbols=%d Success=%d Processed=%d",
      symbol_count,
      total_success_count,
      total_processed_count
   );

   if(g_progress_done_steps < g_progress_total_steps)
   {
      g_progress_done_steps = g_progress_total_steps;
      g_progress_detail = "Finalizing...";
      UpdateProgressUi(true);
   }

   if(InpShowProgressComment)
      Comment("AppendNewBars finished.");

}