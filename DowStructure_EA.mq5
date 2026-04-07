//+------------------------------------------------------------------+
//|                                             DowStructure_EA.mq5  |
//|        Institutional Price Action EA for US30 (Dow Jones)       |
//|        Logic: S&R Zone + Market Structure + Candle Confirmation  |
//+------------------------------------------------------------------+
#property copyright "Reiz"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//=== Identity / Risk ===
input string  InpSymbolName      = "US30";    // Broker symbol (US30/DJ30/DJIA)
input double  InpRiskPercent     = 1.0;       // Risk % per trade
input double  InpDailyLossLimit  = 4.0;       // Daily loss limit %
input int     InpMaxTradesPerDay = 3;
input int     InpMaxOpenTrades   = 2;
input int     InpMagic           = 20260409;

//=== Timeframes ===
input ENUM_TIMEFRAMES InpHTF     = PERIOD_H4;  // Structure / zones
input ENUM_TIMEFRAMES InpETF     = PERIOD_M15; // Entry confirmation (US30 moves fast)

//=== Zone / Structure ===
input int     InpZoneLookback    = 300;        // HTF bars scanned
input int     InpZonePoints      = 35;         // Zone half-width in INDEX points
input int     InpMinTouches      = 2;
input int     InpStructureBars   = 60;
input bool    InpUseRoundNumbers = true;       // Add 100/500/1000 round levels
input int     InpRoundStep       = 500;        // Round number step

//=== Trade Management (US30 in points) ===
input int     InpSLBufferPts     = 25;         // SL buffer beyond zone
input int     InpMinSLPts        = 80;         // Min SL distance (US30 is volatile)
input int     InpMaxSLPts        = 250;        // Max SL distance
input double  InpRR_TP1          = 1.0;
input double  InpRR_TP2          = 2.0;
input double  InpPartialClosePct = 50.0;
input bool    InpUseTrailing     = true;
input double  InpTrailStartR     = 1.0;
input int     InpTrailDistPts    = 60;

//=== Filters ===
input int     InpMaxSpreadPoints = 50;
input bool    InpUseSessionFilter= true;
input int     InpSessionStartGMT = 14;         // 14:30 GMT = US open (we use 14)
input int     InpSessionEndGMT   = 21;         // 21:00 GMT = US close
input bool    InpAllowPreMarket  = true;       // 13:00–14:30 GMT, half size
input int     InpPreMarketStart  = 13;
input double  InpPreMarketSize   = 0.5;        // 50% size in pre-market
input bool    InpUseNewsFilter   = true;
input int     InpNewsBufferMin   = 30;

//=== Globals ===
double   g_point;
datetime g_lastBarETF = 0;
datetime g_dayStart   = 0;
double   g_dayStartEquity = 0;
int      g_tradesToday = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(_Symbol, InpSymbolName) < 0)
   {
      PrintFormat("DowStructure EA: wrong symbol. Expected %s, got %s", InpSymbolName, _Symbol);
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(g_point<=0) g_point = 1.0; // index fallback
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) {}

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
   if(g_dayStartEquity<=0) return false;
   double dd = (g_dayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartEquity * 100.0;
   return (dd >= InpDailyLossLimit);
}

//+------------------------------------------------------------------+
//| Session: regular = full size, pre-market = half size, else block |
//+------------------------------------------------------------------+
int SessionState()  // 0=blocked, 1=regular, 2=pre-market
{
   if(!InpUseSessionFilter) return 1;
   MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;
   if(h>=InpSessionStartGMT && h<InpSessionEndGMT) return 1;
   if(InpAllowPreMarket && h>=InpPreMarketStart && h<InpSessionStartGMT) return 2;
   return 0;
}

//+------------------------------------------------------------------+
bool NewsBlocked()
{
   if(!InpUseNewsFilter) return false;
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - InpNewsBufferMin*60;
   datetime to   = TimeCurrent() + InpNewsBufferMin*60;
   int n = CalendarValueHistory(values, from, to, NULL, "USD");
   for(int i=0;i<n;i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance == CALENDAR_IMPORTANCE_HIGH) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(PositionSelectByTicket(tk) &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
   }
   return c;
}

//+------------------------------------------------------------------+
//| HTF Market Structure                                             |
//+------------------------------------------------------------------+
int MarketStructure()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   int n = CopyRates(_Symbol, InpHTF, 0, InpStructureBars, r);
   if(n<20) return 0;
   double highs[5], lows[5];
   int hi=0, li=0;
   for(int i=2;i<n-2 && (hi<5 || li<5);i++)
   {
      if(hi<5 && r[i].high>r[i-1].high && r[i].high>r[i-2].high &&
                  r[i].high>r[i+1].high && r[i].high>r[i+2].high) highs[hi++]=r[i].high;
      if(li<5 && r[i].low<r[i-1].low && r[i].low<r[i-2].low &&
                  r[i].low<r[i+1].low && r[i].low<r[i+2].low) lows[li++]=r[i].low;
   }
   if(hi<2 || li<2) return 0;
   bool bullish = (highs[0]>highs[1]) && (lows[0]>lows[1]);
   bool bearish = (highs[0]<highs[1]) && (lows[0]<lows[1]);
   if(bullish) return  1;
   if(bearish) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Zone detection (with optional round-number boost)                |
//+------------------------------------------------------------------+
struct Zone { double hi; double lo; double mid; int touches; bool isSupport; int score; };

bool FindNearestZone(bool support, Zone &out)
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   int copied = CopyRates(_Symbol, InpHTF, 0, InpZoneLookback, r);
   if(copied<20) return false;

   double zoneHalf = InpZonePoints * g_point;
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double bestDist = DBL_MAX;
   bool found=false;

   for(int i=2;i<copied-2;i++)
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

      int touches=0;
      for(int j=0;j<copied;j++)
      {
         double p = support ? r[j].low : r[j].high;
         if(MathAbs(p-pivot) <= zoneHalf) touches++;
      }
      if(touches < InpMinTouches) continue;

      if(support && pivot >= curPrice) continue;
      if(!support && pivot <= curPrice) continue;

      // Score: touches + round-number bonus
      int score = touches;
      if(InpUseRoundNumbers)
      {
         double nearest = MathRound(pivot/InpRoundStep)*InpRoundStep;
         if(MathAbs(pivot - nearest) <= zoneHalf) score += 3;
      }

      double dist = MathAbs(curPrice - pivot);
      if(dist < bestDist)
      {
         bestDist = dist;
         out.mid = pivot;
         out.hi  = pivot + zoneHalf;
         out.lo  = pivot - zoneHalf;
         out.touches = touches;
         out.score = score;
         out.isSupport = support;
         found = true;
      }
   }
   return found;
}

//+------------------------------------------------------------------+
//| Candle confirmation on ETF                                       |
//+------------------------------------------------------------------+
bool BullishConfirm()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, InpETF, 0, 3, r)<3) return false;
   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range<=0) return false;
   bool engulf = (r[1].close>r[1].open) && (r[2].close<r[2].open) &&
                 (r[1].close>=r[2].open) && (r[1].open<=r[2].close);
   double lw = MathMin(r[1].open,r[1].close) - r[1].low;
   bool pin = (lw >= 2*body) && (r[1].close>r[1].open);
   return engulf || pin;
}
bool BearishConfirm()
{
   MqlRates r[]; ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol, InpETF, 0, 3, r)<3) return false;
   double body  = MathAbs(r[1].close - r[1].open);
   double range = r[1].high - r[1].low;
   if(range<=0) return false;
   bool engulf = (r[1].close<r[1].open) && (r[2].close>r[2].open) &&
                 (r[1].close<=r[2].open) && (r[1].open>=r[2].close);
   double uw = r[1].high - MathMax(r[1].open,r[1].close);
   bool star = (uw >= 2*body) && (r[1].close<r[1].open);
   return engulf || star;
}

//+------------------------------------------------------------------+
double CalcLot(double slDist, double sizeMult)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk = bal * InpRiskPercent / 100.0 * sizeMult;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0||tickSize<=0) return 0;
   double lossPerLot = (slDist/tickSize)*tickVal;
   if(lossPerLot<=0) return 0;
   double lot = risk/lossPerLot;
   double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double mx=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double st=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/st)*st;
   return MathMax(mn, MathMin(mx, lot));
}

//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double price= (type==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol,SYMBOL_BID)
                                              : SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double rDist = MathAbs(open - sl);
      if(rDist<=0) continue;
      double rNow = (type==POSITION_TYPE_BUY) ? (price-open)/rDist : (open-price)/rDist;

      string cmt = PositionGetString(POSITION_COMMENT);
      if(rNow >= InpRR_TP1 && StringFind(cmt,"P1")<0)
      {
         double closeVol = NormalizeDouble(vol*InpPartialClosePct/100.0, 2);
         double mn=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         if(closeVol>=mn && closeVol<vol)
         {
            if(trade.PositionClosePartial(tk, closeVol))
               trade.PositionModify(tk, open, PositionGetDouble(POSITION_TP));
         }
      }

      if(InpUseTrailing && rNow >= InpTrailStartR)
      {
         double trail = InpTrailDistPts * g_point;
         if(type==POSITION_TYPE_BUY)
         {
            double newSL = price - trail;
            if(newSL > sl) trade.PositionModify(tk, newSL, PositionGetDouble(POSITION_TP));
         }
         else
         {
            double newSL = price + trail;
            if(newSL < sl || sl==0) trade.PositionModify(tk, newSL, PositionGetDouble(POSITION_TP));
         }
      }
   }
}

//+------------------------------------------------------------------+
void TryTrade()
{
   if(g_tradesToday >= InpMaxTradesPerDay) return;
   if(CountOpenTrades() >= InpMaxOpenTrades) return;
   if(DailyLossHit()) return;

   int sess = SessionState();
   if(sess==0) return;
   double sizeMult = (sess==2) ? InpPreMarketSize : 1.0;

   if(NewsBlocked()) return;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPoints) return;

   int bias = MarketStructure();
   if(bias==0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   //--- BUY
   if(bias>0)
   {
      Zone z;
      if(FindNearestZone(true, z))
      {
         if(bid>=z.lo && bid<=z.hi && BullishConfirm())
         {
            double sl = z.lo - InpSLBufferPts*g_point;
            double slDist = ask - sl;
            double slPts = slDist / g_point;
            if(slPts>=InpMinSLPts && slPts<=InpMaxSLPts)
            {
               double tp = ask + slDist*InpRR_TP2;
               double lot = CalcLot(slDist, sizeMult);
               if(lot>0 && trade.Buy(lot,_Symbol,ask,sl,tp,"DS-Buy"))
                  g_tradesToday++;
               return;
            }
         }
      }
   }

   //--- SELL
   if(bias<0)
   {
      Zone z;
      if(FindNearestZone(false, z))
      {
         if(bid>=z.lo && bid<=z.hi && BearishConfirm())
         {
            double sl = z.hi + InpSLBufferPts*g_point;
            double slDist = sl - bid;
            double slPts = slDist / g_point;
            if(slPts>=InpMinSLPts && slPts<=InpMaxSLPts)
            {
               double tp = bid - slDist*InpRR_TP2;
               double lot = CalcLot(slDist, sizeMult);
               if(lot>0 && trade.Sell(lot,_Symbol,bid,sl,tp,"DS-Sell"))
                  g_tradesToday++;
               return;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckNewDay();
   ManagePositions();

   datetime t = iTime(_Symbol, InpETF, 0);
   if(t == g_lastBarETF) return;
   g_lastBarETF = t;

   TryTrade();
}
//+------------------------------------------------------------------+
