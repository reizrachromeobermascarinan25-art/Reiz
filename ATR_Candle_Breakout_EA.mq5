//+------------------------------------------------------------------+
//|                                    ATR_Candle_Breakout_EA.mq5    |
//|                        ATR Candle Breakout Expert Advisor         |
//|                     Optimized for S&P 500 Index on MT5           |
//+------------------------------------------------------------------+
#property copyright   "ATR Candle Breakout EA - SP500"
#property link        ""
#property version     "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Groups                                                      |
//+------------------------------------------------------------------+

//--- Strategy Parameters
input group "=== Strategy Settings ==="
input ENUM_TIMEFRAMES InpATRTimeframe      = PERIOD_M15;   // ATR Timeframe
input int             InpATRPeriod         = 14;           // ATR Period
input double          InpATRBodyMultiplier = 1.2;          // Candle Body / ATR Multiplier
input double          InpCloseZonePercent  = 40.0;         // Close Zone % from High/Low

//--- Risk Management
input group "=== Risk Management ==="
input double InpRiskAmount       = 100.0;   // Fixed Risk Amount (account currency)
input double InpSLPercent        = 0.5;     // Stop Loss % of open price (0.5% for SP500)
input double InpTPPercent        = 1.0;     // Take Profit % of open price (1:2 RR)
input int    InpMaxTradesPerDay  = 5;       // Max Trades Per Day
input double InpMaxDailyLossPct  = 3.0;     // Max Daily Loss % of Balance (pause EA)

//--- Filters
input group "=== Filters ==="
input int    InpMaxSpreadPoints  = 30;      // Max Spread (points, 0=disabled)
input double InpMinATRPoints     = 20.0;    // Min ATR (points, loose floor for SP500)
input bool   InpUseTrendFilter   = false;   // Enable EMA200 Trend Filter
input int    InpEMAPeriod        = 200;     // EMA Period (if enabled)
input bool   InpUseRSIFilter     = false;   // Enable RSI Filter
input int    InpRSIPeriod        = 14;      // RSI Period
input double InpRSIOverbought    = 80.0;    // RSI Overbought Level
input double InpRSIOversold      = 20.0;    // RSI Oversold Level

//--- Session Filter
input group "=== Session Filter ==="
input bool InpUseSessionFilter  = false;  // Enable Session Filter
input bool InpTradePreMarket    = true;   // Allow Pre-Market (server 10:00-14:30)
input int  InpUSMarketStart     = 14;     // US Market Open Hour (server time ~14:30 UTC)
input int  InpUSMarketEnd       = 21;     // US Market Close Hour (server time ~21:00 UTC)
input bool InpTradeAfterHours   = false;  // Allow After-Hours Trading

//--- Trade Management
input group "=== Trade Management ==="
input bool   InpUseBreakEven     = true;    // Enable Break-Even
input bool   InpUseTrailingStop  = false;   // Enable Trailing Stop (trail by 1×ATR)
input bool   InpCloseEndOfDay    = false;   // Close Trades End-of-Day
input int    InpEndOfDayHour     = 21;      // End-of-Day Hour (21=US market close)

//--- Notifications & Visuals
input group "=== Notifications & Visuals ==="
input bool InpPushNotification = false;  // Send Push Notification on Trade
input bool InpShowDashboard    = true;   // Show On-Chart Dashboard
input int  InpMagicNumber      = 500500; // EA Magic Number

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
int            handleATR;
int            handleEMA;
int            handleRSI;
datetime       lastBarTime;
double         dailyStartBalance;
datetime       dailyResetTime;
int            tradesToday;
string         dashboardPrefix = "ATRBO_";

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Create ATR indicator
   handleATR = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   if(handleATR == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create ATR indicator");
      return INIT_FAILED;
   }

   //--- Create EMA indicator if enabled
   if(InpUseTrendFilter)
   {
      handleEMA = iMA(_Symbol, InpATRTimeframe, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(handleEMA == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create EMA indicator");
         return INIT_FAILED;
      }
   }
   else
      handleEMA = INVALID_HANDLE;

   //--- Create RSI indicator if enabled
   if(InpUseRSIFilter)
   {
      handleRSI = iRSI(_Symbol, InpATRTimeframe, InpRSIPeriod, PRICE_CLOSE);
      if(handleRSI == INVALID_HANDLE)
      {
         Print("ERROR: Failed to create RSI indicator");
         return INIT_FAILED;
      }
   }
   else
      handleRSI = INVALID_HANDLE;

   //--- Initialize daily tracking
   lastBarTime       = 0;
   tradesToday       = 0;
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyResetTime    = GetStartOfDay(TimeCurrent());

   Print("ATR Candle Breakout EA (SP500) initialized | Symbol: ", _Symbol,
         " | ATR TF: ", EnumToString(InpATRTimeframe),
         " | Magic: ", InpMagicNumber);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleEMA != INVALID_HANDLE) IndicatorRelease(handleEMA);
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);

   CleanupDashboard();
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Daily reset check
   CheckDailyReset();

   //--- End-of-day close
   if(InpCloseEndOfDay)
      CheckEndOfDayClose();

   //--- Trade management (break-even / trailing) runs every tick
   ManageOpenTrades();

   //--- New bar detection — main logic only on bar close
   if(!IsNewBar())
      return;

   //--- Dashboard update on each new bar
   if(InpShowDashboard)
      UpdateDashboard();

   //--- Daily loss limit check
   if(IsDailyLossLimitHit())
   {
      Print("Daily loss limit reached. EA paused for today.");
      return;
   }

   //--- Max trades per day
   if(tradesToday >= InpMaxTradesPerDay)
   {
      Print("Max trades per day (", InpMaxTradesPerDay, ") reached.");
      return;
   }

   //--- Spread filter
   if(InpMaxSpreadPoints > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > (long)InpMaxSpreadPoints)
      {
         Print("Spread too high: ", spread, " > ", InpMaxSpreadPoints);
         return;
      }
   }

   //--- Session filter
   if(InpUseSessionFilter && !IsWithinSession())
   {
      Print("Outside allowed trading sessions.");
      return;
   }

   //--- Get ATR value (bar index 1 = last closed bar)
   double atrBuffer[];
   if(CopyBuffer(handleATR, 0, 1, 1, atrBuffer) <= 0)
   {
      Print("ERROR: Failed to copy ATR buffer");
      return;
   }
   double atrValue = atrBuffer[0];

   //--- Min ATR filter
   double pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(pointSize == 0) return;

   double atrInPoints = atrValue / pointSize;
   if(InpMinATRPoints > 0 && atrInPoints < InpMinATRPoints)
   {
      Print("ATR too low: ", DoubleToString(atrInPoints, 1), " points < ", InpMinATRPoints);
      return;
   }

   //--- Get last closed candle data
   double open1  = iOpen(_Symbol, InpATRTimeframe, 1);
   double high1  = iHigh(_Symbol, InpATRTimeframe, 1);
   double low1   = iLow(_Symbol, InpATRTimeframe, 1);
   double close1 = iClose(_Symbol, InpATRTimeframe, 1);

   if(open1 == 0 || high1 == 0 || low1 == 0 || close1 == 0) return;

   double bodySize  = MathAbs(close1 - open1);
   double candleRange = high1 - low1;
   if(candleRange == 0) return;

   //--- ATR breakout check: body > multiplier × ATR
   if(bodySize < InpATRBodyMultiplier * atrValue)
      return;

   //--- Determine direction
   bool isBullish = (close1 > open1);
   bool isBearish = (close1 < open1);
   if(!isBullish && !isBearish) return;

   //--- Close zone filter
   double closeZonePct = InpCloseZonePercent / 100.0;
   if(isBullish)
   {
      // Close must be within top closeZonePct of candle range
      double threshold = high1 - candleRange * closeZonePct;
      if(close1 < threshold)
      {
         Print("BUY signal rejected: close not in top ", InpCloseZonePercent, "% zone");
         return;
      }
   }
   else // isBearish
   {
      // Close must be within bottom closeZonePct of candle range
      double threshold = low1 + candleRange * closeZonePct;
      if(close1 > threshold)
      {
         Print("SELL signal rejected: close not in bottom ", InpCloseZonePercent, "% zone");
         return;
      }
   }

   //--- EMA trend filter (optional)
   if(InpUseTrendFilter && handleEMA != INVALID_HANDLE)
   {
      double emaBuffer[];
      if(CopyBuffer(handleEMA, 0, 1, 1, emaBuffer) <= 0)
      {
         Print("ERROR: Failed to copy EMA buffer");
         return;
      }
      double emaValue = emaBuffer[0];

      if(isBullish && close1 < emaValue)
      {
         Print("BUY rejected by EMA filter: close ", close1, " < EMA ", emaValue);
         return;
      }
      if(isBearish && close1 > emaValue)
      {
         Print("SELL rejected by EMA filter: close ", close1, " > EMA ", emaValue);
         return;
      }
   }

   //--- RSI filter (optional)
   if(InpUseRSIFilter && handleRSI != INVALID_HANDLE)
   {
      double rsiBuffer[];
      if(CopyBuffer(handleRSI, 0, 1, 1, rsiBuffer) <= 0)
      {
         Print("ERROR: Failed to copy RSI buffer");
         return;
      }
      double rsiValue = rsiBuffer[0];

      if(isBullish && rsiValue > InpRSIOverbought)
      {
         Print("BUY rejected by RSI filter: RSI ", DoubleToString(rsiValue, 1), " > ", InpRSIOverbought);
         return;
      }
      if(isBearish && rsiValue < InpRSIOversold)
      {
         Print("SELL rejected by RSI filter: RSI ", DoubleToString(rsiValue, 1), " < ", InpRSIOversold);
         return;
      }
   }

   //--- Calculate trade parameters
   double entryPrice = isBullish ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDistance = entryPrice * InpSLPercent / 100.0;
   double tpDistance = entryPrice * InpTPPercent / 100.0;

   double sl, tp;
   if(isBullish)
   {
      sl = entryPrice - slDistance;
      tp = entryPrice + tpDistance;
   }
   else
   {
      sl = entryPrice + slDistance;
      tp = entryPrice - tpDistance;
   }

   //--- Normalize prices to tick size
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
   {
      entryPrice = NormalizeToTick(entryPrice, tickSize);
      sl         = NormalizeToTick(sl, tickSize);
      tp         = NormalizeToTick(tp, tickSize);
   }

   //--- Calculate lot size based on fixed risk
   double lotSize = CalculateLotSize(slDistance);
   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated");
      return;
   }

   //--- Execute trade
   string comment = StringFormat("ATRBO|ATR=%.2f|Body=%.2f", atrValue, bodySize);

   bool result = false;
   if(isBullish)
      result = trade.Buy(lotSize, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(lotSize, _Symbol, 0, sl, tp, comment);

   if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      tradesToday++;
      string direction = isBullish ? "BUY" : "SELL";
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      Print("Trade opened: ", direction,
            " | Lots: ", DoubleToString(lotSize, 2),
            " | Entry: ", DoubleToString(entryPrice, digits),
            " | SL: ", DoubleToString(sl, digits),
            " | TP: ", DoubleToString(tp, digits),
            " | ATR: ", DoubleToString(atrValue, digits));

      //--- Chart label on signal candle
      CreateSignalLabel(isBullish, atrValue, bodySize, high1, low1);

      //--- Push notification
      if(InpPushNotification)
      {
         string msg = StringFormat("ATRBO %s | %s | Lots: %.2f | ATR: %.2f",
                                    direction, _Symbol, lotSize, atrValue);
         SendNotification(msg);
      }
   }
   else
   {
      Print("ERROR: Trade failed | Retcode: ", trade.ResultRetcode(),
            " | Comment: ", trade.ResultComment());
   }
}

//+------------------------------------------------------------------+
//| New bar detection                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, InpATRTimeframe, 0);
   if(currentBarTime == 0) return false;

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get start of current server day                                   |
//+------------------------------------------------------------------+
datetime GetStartOfDay(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Daily reset: trade counter and balance snapshot                   |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime todayStart = GetStartOfDay(TimeCurrent());
   if(todayStart != dailyResetTime)
   {
      dailyResetTime    = todayStart;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      tradesToday       = 0;
      Print("Daily reset | Balance snapshot: ", DoubleToString(dailyStartBalance, 2));
   }
}

//+------------------------------------------------------------------+
//| Check if daily loss limit is hit                                  |
//+------------------------------------------------------------------+
bool IsDailyLossLimitHit()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double lowestValue    = MathMin(currentBalance, currentEquity);
   double dailyPL        = lowestValue - dailyStartBalance;
   double maxLoss        = dailyStartBalance * InpMaxDailyLossPct / 100.0;

   return (dailyPL < 0 && MathAbs(dailyPL) >= maxLoss);
}

//+------------------------------------------------------------------+
//| Session filter — US equity market focused                         |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;

   //--- Skip weekends (Saturday=6, Sunday=0)
   if(dt.day_of_week == 0 || dt.day_of_week == 6)
      return false;

   //--- Pre-market session (typically 10:00-14:30 server/UTC)
   if(InpTradePreMarket && hour >= 10 && hour < InpUSMarketStart)
      return true;

   //--- Regular US market hours
   if(InpUSMarketStart <= InpUSMarketEnd)
   {
      if(hour >= InpUSMarketStart && hour < InpUSMarketEnd)
         return true;
   }
   else
   {
      if(hour >= InpUSMarketStart || hour < InpUSMarketEnd)
         return true;
   }

   //--- After-hours session (typically 21:00-23:00 server/UTC)
   if(InpTradeAfterHours && hour >= InpUSMarketEnd && hour < 23)
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Normalize price to tick size                                      |
//+------------------------------------------------------------------+
double NormalizeToTick(double price, double tickSize)
{
   if(tickSize == 0) return price;
   return MathRound(price / tickSize) * tickSize;
}

//+------------------------------------------------------------------+
//| Calculate lot size from fixed risk and SL distance                |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0) return 0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tickSize == 0 || tickValue == 0 || lotStep == 0) return 0;

   double ticksInSL = slDistance / tickSize;
   double lossPerLot = ticksInSL * tickValue;

   if(lossPerLot <= 0) return 0;

   double lots = InpRiskAmount / lossPerLot;

   // Round down to lot step
   lots = MathFloor(lots / lotStep) * lotStep;

   // Clamp to broker limits
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Manage open trades: break-even and trailing stop                  |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   if(!InpUseBreakEven && !InpUseTrailingStop) return;

   double atrValue = 0;
   if(InpUseTrailingStop)
   {
      double atrBuf[];
      if(CopyBuffer(handleATR, 0, 0, 1, atrBuf) > 0)
         atrValue = atrBuf[0];
   }

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      long   posType   = PositionGetInteger(POSITION_TYPE);

      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double slDistance = openPrice * InpSLPercent / 100.0;  // 1R distance

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profitDistance = bid - openPrice;

         //--- Break-even: move SL to entry once profit >= 1R
         if(InpUseBreakEven && profitDistance >= slDistance && currentSL < openPrice)
         {
            double newSL = NormalizeToTick(openPrice, tickSize);
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("Break-even set for BUY #", ticket);
            continue; // Don't also trail on the same tick
         }

         //--- Trailing stop: trail by 1×ATR
         if(InpUseTrailingStop && atrValue > 0 && profitDistance > 0)
         {
            double trailSL = NormalizeToTick(bid - atrValue, tickSize);
            if(trailSL > currentSL && trailSL > openPrice)
            {
               if(trade.PositionModify(ticket, trailSL, currentTP))
                  Print("Trailing stop updated for BUY #", ticket,
                        " | New SL: ", DoubleToString(trailSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitDistance = openPrice - ask;

         //--- Break-even
         if(InpUseBreakEven && profitDistance >= slDistance && (currentSL > openPrice || currentSL == 0))
         {
            double newSL = NormalizeToTick(openPrice, tickSize);
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print("Break-even set for SELL #", ticket);
            continue;
         }

         //--- Trailing stop
         if(InpUseTrailingStop && atrValue > 0 && profitDistance > 0)
         {
            double trailSL = NormalizeToTick(ask + atrValue, tickSize);
            if(trailSL < currentSL || currentSL == 0)
            {
               if(trailSL < openPrice)
               {
                  if(trade.PositionModify(ticket, trailSL, currentTP))
                     Print("Trailing stop updated for SELL #", ticket,
                           " | New SL: ", DoubleToString(trailSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| End-of-day close                                                  |
//+------------------------------------------------------------------+
void CheckEndOfDayClose()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.hour >= InpEndOfDayHour)
   {
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         if(trade.PositionClose(ticket))
            Print("End-of-day close: Position #", ticket);
         else
            Print("ERROR: Failed to close position #", ticket, " | ", trade.ResultComment());
      }
   }
}

//+------------------------------------------------------------------+
//| Create signal label on chart                                      |
//+------------------------------------------------------------------+
void CreateSignalLabel(bool isBuy, double atrVal, double bodyVal,
                       double candleHigh, double candleLow)
{
   string name = dashboardPrefix + "SIG_" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   int digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string text = StringFormat("%s | ATR: %s | Body: %s",
                              isBuy ? "BUY" : "SELL",
                              DoubleToString(atrVal, digits),
                              DoubleToString(bodyVal, digits));

   double price = isBuy ? candleHigh + atrVal * 0.2
                        : candleLow  - atrVal * 0.2;

   datetime barTime = iTime(_Symbol, InpATRTimeframe, 1);

   ObjectDelete(0, name);
   if(ObjectCreate(0, name, OBJ_TEXT, 0, barTime, price))
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, isBuy ? clrLime : clrRed);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, isBuy ? ANCHOR_LOWER : ANCHOR_UPPER);
   }
}

//+------------------------------------------------------------------+
//| Update on-chart dashboard                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   //--- ATR
   double atrVal = 0;
   double atrBuf[];
   if(CopyBuffer(handleATR, 0, 0, 1, atrBuf) > 0)
      atrVal = atrBuf[0];

   //--- Daily P&L
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - dailyStartBalance;

   //--- EA Status
   string status = "ACTIVE";
   if(IsDailyLossLimitHit())
      status = "PAUSED (Daily Loss)";
   else if(tradesToday >= InpMaxTradesPerDay)
      status = "PAUSED (Max Trades)";

   //--- Build dashboard text
   string dash = "";
   dash += "--- ATR Candle Breakout EA (SP500) ---\n";
   dash += StringFormat("Symbol:       %s\n", _Symbol);
   dash += StringFormat("Spread:       %d pts\n", (int)spread);
   dash += StringFormat("ATR(%d):      %s\n", InpATRPeriod, DoubleToString(atrVal, digits));
   dash += StringFormat("SL/TP:        %.1f%% / %.1f%%\n", InpSLPercent, InpTPPercent);
   dash += StringFormat("Daily P&L:    %s\n", DoubleToString(dailyPL, 2));
   dash += StringFormat("Trades Today: %d / %d\n", tradesToday, InpMaxTradesPerDay);
   dash += StringFormat("Status:       %s\n", status);

   if(InpUseTrendFilter)   dash += "EMA Filter:   ON\n";
   if(InpUseRSIFilter)     dash += "RSI Filter:   ON\n";
   if(InpUseSessionFilter) dash += "Session Flt:  ON\n";

   Comment(dash);
}

//+------------------------------------------------------------------+
//| Clean up dashboard objects                                        |
//+------------------------------------------------------------------+
void CleanupDashboard()
{
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, dashboardPrefix) == 0)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+
