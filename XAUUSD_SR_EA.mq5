//+------------------------------------------------------------------+
//|                                                XAUUSD_SR_EA.mq5  |
//|       Support & Resistance Strategy EA for XAUUSD (Gold)         |
//|       Implements HTF S&R zones + ETF candle confirmation         |
//+------------------------------------------------------------------+
#property copyright "Reiz"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//--- Inputs: Risk Management
input double InpRiskPercent      = 1.0;     // Risk % per trade
input double InpDailyLossLimit   = 4.0;     // Daily loss limit %
input int    InpMaxTradesPerDay  = 4;       // Max trades per day
input int    InpMaxOpenTrades    = 2;       // Max simultaneous trades
input int    InpMagic            = 20260407;

//--- Inputs: Strategy
input ENUM_TIMEFRAMES InpHTF     = PERIOD_H4;   // Higher timeframe
input ENUM_TIMEFRAMES InpETF     = PERIOD_H1;   // Entry timeframe
input int    InpZoneLookback     = 200;     // Bars to scan for S&R
input int    InpZoneWidthPips    = 20;      // Zone width (pips)
input int    InpMinTouches       = 2;       // Min reaction touches
input int    InpSLBufferPips     = 15;      // SL buffer beyond zone
input int    InpMinSLPips        = 30;      // Min SL distance
input int    InpMaxSLPips        = 80;      // Max SL distance
input double InpMinRR            = 2.0;     // Minimum R:R
input int    InpMaxSpreadPoints  = 35;      // Max allowed spread
input int    InpRSIPeriod        = 14;
input int    InpEMAPeriod        = 200;
input int    InpATRPeriod        = 14;
input double InpATRSpikeMult     = 1.2;     // ATR spike threshold

//--- Inputs: Sessions (GMT hours)
input bool   InpUseSessionFilter = true;
input int    InpLondonStart      = 8;
input int    InpLondonEnd        = 10;
input int    InpNYStart          = 13;
input int    InpNYEnd            = 15;

//--- Globals
int    hRSI, hEMA, hATR;
double g_pip;
datetime g_lastBarETF = 0;
datetime g_dayStart = 0;
double g_dayStartEquity = 0;
int    g_tradesToday = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   hRSI = iRSI(_Symbol, InpETF, InpRSIPeriod, PRICE_CLOSE);
   hEMA = iMA(_Symbol, InpETF, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hATR = iATR(_Symbol, InpETF, InpATRPeriod);
   if(hRSI==INVALID_HANDLE || hEMA==INVALID_HANDLE || hATR==INVALID_HANDLE)
      return INIT_FAILED;

   // Gold pip = 0.10 (5-digit) or 0.01 (3-digit). Use 0.1 for XAUUSD standard.
   g_pip = (_Digits==2 || _Digits==3) ? 0.01 : 0.1;
   if(StringFind(_Symbol,"XAU")>=0) g_pip = 0.1;

   g_dayStart = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hRSI);
   IndicatorRelease(hEMA);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| Daily reset                                                      |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != g_dayStart)
   {
      g_dayStart = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday = 0;
   }
}

bool DailyLossHit()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (g_dayStartEquity - eq) / g_dayStartEquity * 100.0;
   return (dd >= InpDailyLossLimit);
}

bool InSession()
{
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   return ((h>=InpLondonStart && h<InpLondonEnd) || (h>=InpNYStart && h<InpNYEnd));
}

int CountOpenTrades()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==InpMagic
         && PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
   }
   return c;
}

//+------------------------------------------------------------------+
//| S&R Zone detection from HTF swing highs/lows                     |
//+------------------------------------------------------------------+
struct Zone { double hi; double lo; int touches; bool isSupport; };

bool FindNearestZone(bool support, Zone &out)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, InpHTF, 0, InpZoneLookback, r);
   if(copied < 20) return false;

   double zoneHalf = InpZoneWidthPips * g_pip / 2.0;
   double bestDist = DBL_MAX;
   bool found=false;
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Identify swing points (fractal-style, 2 bars each side)
   for(int i=2; i<copied-2; i++)
   {
      double pivot;
      bool isPivot;
      if(support)
      {
         pivot = r[i].low;
         isPivot = (r[i].low<r[i-1].low && r[i].low<r[i-2].low &&
                    r[i].low<r[i+1].low && r[i].low<r[i+2].low);
      }
      else
      {
         pivot = r[i].high;
         isPivot = (r[i].high>r[i-1].high && r[i].high>r[i-2].high &&
                    r[i].high>r[i+1].high && r[i].high>r[i+2].high);
      }
      if(!isPivot) continue;

      // count touches within zone width
      int touches=0;
      for(int j=0;j<copied;j++)
      {
         double p = support ? r[j].low : r[j].high;
         if(MathAbs(p - pivot) <= zoneHalf) touches++;
      }
      if(touches < InpMinTouches) continue;

      // valid side relative to current price
      if(support && pivot >= curPrice) continue;
      if(!support && pivot <= curPrice) continue;

      double dist = MathAbs(curPrice - pivot);
      if(dist < bestDist)
      {
         bestDist = dist;
         out.hi = pivot + zoneHalf;
         out.lo = pivot - zoneHalf;
         out.touches = touches;
         out.isSupport = support;
         found = true;
      }
   }
   return found;
}

//+------------------------------------------------------------------+
//| Candle confirmation on ETF (last closed bar = index 1)           |
//+------------------------------------------------------------------+
bool BullishConfirmation()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, InpETF, 0, 3, r) < 3) return false;
   double body = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range<=0) return false;
   // Bullish engulfing
   bool engulf = (r[1].close > r[1].open) && (r[2].close < r[2].open) &&
                 (r[1].close >= r[2].open) && (r[1].open <= r[2].close);
   // Hammer / pin
   double lowerWick = MathMin(r[1].open,r[1].close) - r[1].low;
   bool hammer = (lowerWick >= 2*body) && (r[1].close > r[1].open);
   return engulf || hammer;
}

bool BearishConfirmation()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, InpETF, 0, 3, r) < 3) return false;
   double body = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range<=0) return false;
   bool engulf = (r[1].close < r[1].open) && (r[2].close > r[2].open) &&
                 (r[1].close <= r[2].open) && (r[1].open >= r[2].close);
   double upperWick = r[1].high - MathMax(r[1].open,r[1].close);
   bool star = (upperWick >= 2*body) && (r[1].close < r[1].open);
   return engulf || star;
}

//+------------------------------------------------------------------+
//| Position sizing by risk %                                        |
//+------------------------------------------------------------------+
double CalcLot(double slPriceDist)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0 || tickVal<=0) return 0.0;
   double lossPerLot = (slPriceDist / tickSize) * tickVal;
   if(lossPerLot<=0) return 0.0;
   double lot = riskMoney / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step)*step;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
//| Indicator helpers                                                |
//+------------------------------------------------------------------+
double GetVal(int handle, int shift=1)
{
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(handle,0,shift,1,b)<1) return 0.0;
   return b[0];
}

bool ATRSpike()
{
   double a[]; ArraySetAsSeries(a,true);
   if(CopyBuffer(hATR,0,1,20,a)<20) return false;
   double avg=0; for(int i=1;i<20;i++) avg+=a[i];
   avg/=19.0;
   return (a[0] >= avg*InpATRSpikeMult);
}

//+------------------------------------------------------------------+
//| Main trade logic                                                 |
//+------------------------------------------------------------------+
void TryTrade()
{
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(CountOpenTrades() >= InpMaxOpenTrades) return;
   if(DailyLossHit()) return;
   if(!InSession()) return;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double rsi = GetVal(hRSI);
   double ema = GetVal(hEMA);
   if(!ATRSpike()) return;

   // ---- BUY ----
   Zone sup;
   if(FindNearestZone(true, sup))
   {
      bool inZone = (bid >= sup.lo && bid <= sup.hi);
      if(inZone && rsi < 50 && rsi >= 25 && BullishConfirmation())
      {
         double sl = sup.lo - InpSLBufferPips*g_pip;
         double slDist = ask - sl;
         double slPips = slDist / g_pip;
         if(slPips >= InpMinSLPips && slPips <= InpMaxSLPips)
         {
            double tp = ask + slDist * InpMinRR;
            double lot = CalcLot(slDist);
            if(lot>0 && trade.Buy(lot, _Symbol, ask, sl, tp, "SR-Buy"))
               g_tradesToday++;
            return;
         }
      }
   }

   // ---- SELL ----
   Zone res;
   if(FindNearestZone(false, res))
   {
      bool inZone = (bid >= res.lo && bid <= res.hi);
      if(inZone && rsi > 50 && rsi <= 75 && BearishConfirmation())
      {
         double sl = res.hi + InpSLBufferPips*g_pip;
         double slDist = sl - bid;
         double slPips = slDist / g_pip;
         if(slPips >= InpMinSLPips && slPips <= InpMaxSLPips)
         {
            double tp = bid - slDist * InpMinRR;
            double lot = CalcLot(slDist);
            if(lot>0 && trade.Sell(lot, _Symbol, bid, sl, tp, "SR-Sell"))
               g_tradesToday++;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();

   // Run on new ETF bar only
   datetime t = iTime(_Symbol, InpETF, 0);
   if(t == g_lastBarETF) return;
   g_lastBarETF = t;

   TryTrade();
}
//+------------------------------------------------------------------+
