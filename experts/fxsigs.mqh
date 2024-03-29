//+------------------------------------------------------------------+
//|                                                   fxsigs.mq4 |
//            Copyright 2019, Carlos Eduardo Lopez |
//                                        c.lopez@kmels.net |
//+------------------------------------------------------------------+
#property copyright "Copyright 2019, Carlos Eduardo Lopez"
#property link      "c.lopez@kmels.net"
#property version   "1.00"
#property strict

#include <hash.mqh>
#include <json.mqh>
#include <WinUser32.mqh>

int MAX_PENDING_LIFE = 20 * 24 * 3600;
int PRECISION = PERIOD_M1;
int ENTRY_SLIPPAGE = 10; // 1 pip

bool score_busy = false;

class FxSignal: public HashValue{
    public: double entry;
    public: double sl;
    public: double tp;
    public: datetime date;
    public: datetime inserted_at;
    public: int sign;    
    public: string username;
    public: string pair;
    public: long hash;
    public: double kelly;
    double winrate;
    char state;
    public: string json;
    
    FxSignal(double e, double s, double t, datetime d, datetime iat,
            int _sign, string u, string p, long h,
            double k, double wr, char st, string j ) { 
        entry = e; sl = s; tp = t; sign = _sign; date = d; inserted_at = iat;
        username = u; pair = p; hash = h;
        kelly =k; winrate = wr; state = st; json = j; 
    }
};


FxSignal* makeFxSignal(JSONObject *o, string json = ""){
   if (!o) 
      return NULL;
   
   Print("Payload is:: " + json);
   string mt4rep = StringSubstr(o.getString("mt4_rep"),0,16);
   string inserted_at;
   if (o.getValue("inserted_at")!=NULL)
      inserted_at = o.getString("inserted_at");
   else
      inserted_at = mt4rep;
      
   string sign = o.getString("sign");
   string username = o.getString("username");
   string pair = o.getString("pair");
   double e = o.getDouble("entry");
   double sl = o.getDouble("sl");
   double tp = o.getDouble("tp");
   
   int _s = -1;
   if (StringCompare(sign,"SELL",false)==0)
      _s = OP_SELL;
   if (StringCompare(sign,"BUY",false)==0)
      _s = OP_BUY;
   
   char state = '-';
   
   JSONArray *scores = o.getArray("calificaciones");
   if (scores && scores.isArray()){
      for (int i = 0; i < scores.size(); i++){
         if (!scores)
            continue;
         JSONObject *score = scores.getObject(i);
         if (!score) {
            delete score;
            continue;
         }
         string calificador = score.getString("calificador");
         bool match = StringCompare(calificador, AccountCompany()) == 0;
         //Print("Comparing ", calificador, " y ", AccountCompany(), " ...", match);
         if (match){
            string st = score.getString("state");
            state = (char)StringGetChar(st,0);
         }
         delete score;
      }
   }
   delete scores;
      
   double kelly = NULL;
   double win_rate = NULL;
   
   JSONObject* track = o.getObject("track_record");
   if (track && track.getValue("pair_expected_kellyratio")!=NULL) 
      kelly = track.getDouble("pair_expected_kellyratio");   
      
   Print("Kelly track: ", kelly);
   Print("Printing ....");
   Print(json);
   FxSignal* r = new FxSignal(
         e, sl, tp,
         StrToTime(mt4rep), StrToTime(inserted_at),
         _s, username, pair, o.getLong("hash"), kelly, win_rate, state, json
   );
         
   return r;
}

class ScoreResult: public HashValue{
    public: long hash;
    public: datetime published_on;
    public: datetime opened_on;
    public: datetime invalidated_on;
    public: string reason;
    public: string username;
    public: string pair;
    public: char state;
    public: datetime last_checked;
    public: datetime last_available;
    public: int granularity;
    public: FxSignal* signal;
    ScoreResult(long h, datetime po, datetime o, datetime i, string r, 
                 string u, string p, char st, datetime lc, datetime la, int g, FxSignal* sig){
      hash = h; published_on = po; opened_on = o; invalidated_on = i; reason = r; username = u; pair = p; state = st; last_checked = lc; last_available = la; granularity = g;
      signal = sig;
    }
    
    string csv(){
      return IntegerToString(hash)+","+TimeToStr(opened_on)+","+TimeToStr(invalidated_on)+","+reason+","+username+","+pair;
    }
    
    string json(string requester = NULL){
      string j = "{";
      j += "\"hash\": "+IntegerToString(hash);
      if (requester != NULL)
         j += ",\"processor\": \""+requester+"\"";
      j += ",\"calificador\": \""+AccountCompany()+"\"";
      j += ",\"pair\": \""+pair+"\"";
      j += ",\"event\": \""+reason+"\"";
      j += ",\"state\": \""+CharToStr(state)+"\"";
      j += ",\"published_on\": {\"ts\": "+IntegerToString(published_on)+",\"mt4\": \""+TimeToStr(published_on)+"\"}";
      j += ",\"opened_on\": {\"ts\": "+IntegerToString(opened_on)+",\"mt4\": \""+TimeToStr(opened_on)+"\"}";
      j += ",\"invalidated_on\": {\"ts\": "+IntegerToString(invalidated_on)+",\"mt4\": \""+TimeToStr(invalidated_on)+"\"}";
      j += ",\"last_checked\": {\"ts\": "+IntegerToString(last_checked)+",\"mt4\": \""+TimeToStr(last_checked)+"\"}";
      j += ",\"last_available\": {\"ts\": "+IntegerToString(last_available)+",\"mt4\": \""+TimeToStr(last_available)+"\"}";
      if (state == 'O') {
         j += ",\"spot_price\": \""+DoubleToString(MarketInfo(pair, MODE_BID))+"\"";
      }
      if (signal != NULL && StringLen(signal.json) > 0) {
         j += ",\"signal\": " + signal.json;;
      }
      
      j += "}";
      return j;
    }
    
    string pretty(){
    
      bool ENTRYHIT = opened_on > D'01.01.1975';
      bool TPHIT = reason == "tp_hit";
      bool SLHIT = reason == "sl_hit";
      datetime exit_date = invalidated_on;
      datetime execution_date = opened_on;
      string result;
      
      double points = 0;
      
      if (ENTRYHIT){
         if (TPHIT)
            result += "Executed win. %0A Entry date: " + TimeToString(execution_date) + ". Exit date: " + TimeToStr(exit_date-6*60*60);
         else if (SLHIT)
            result += "Executed loss.%0A Entry date: " + TimeToString(execution_date) + ". Exit date: " + TimeToStr(exit_date-6*60*60);
         else {
            double pips = 0;
            
            Print("Signal sign: "+IntegerToString(signal.sign));
            double price = iClose(signal.pair, granularity, 0);
            
            int digits = (int)MarketInfo(signal.pair, MODE_DIGITS); 
            int Human = (int)MathPow(10,digits-1);
            
            if (signal.sign == OP_BUY) {
               pips = (price - signal.entry)*Human;
            }
            if (signal.sign == OP_SELL) {
               pips = (signal.entry - price)*Human;
            }
            
            result += "Open @ ";
            result += "Current 🇪🇺" + signal.pair + "🇨🇦 price: " + DoubleToStr(price,5) + " ";
            if (pips > 0) 
               result += "(➕";
            if (pips < 0) 
               result += "(➖";
            result += DoubleToString(pips,1);
            result += " pips )";
            
            result += ".%0A Entry date: " + TimeToString(execution_date) + ". Last checked: "+TimeToStr(last_checked);
         }
      } else {
         if (TPHIT || (reason == "invalid_tp_hit"))
            result += "Not executed.%0A It hit TP before Entry. TP date: " + 
                     TimeToStr(exit_date) + ". Last checked: "+TimeToStr(last_checked);
         else if (SLHIT  || (reason == "invalid_sl_hit"))
            result += "Not executed.%0A Llego a SL antes que a Entry. SL date: " +
                     TimeToStr(exit_date) + ". Last checked: "+TimeToStr(last_checked);
         else
            result += "Pending. It's not opened."+ ". Last checked: "
            +TimeToStr(last_checked) + ". Last available: "+TimeToStr(last_available);
      }
      if (signal != NULL) {
         result += "Published: " + TimeToString(signal.date) + "<br>";
         result += "Hash: " + IntegerToString(signal.hash) +  "%5Cn%0D%0A";
      }
      return result;
    }
};

bool is_price_executed_within(string pair, int timeframe, int shift, double entry_price, int trade_type, int slippage_points = 0) {
   double spread = (double) MarketInfo(pair, MODE_SPREAD);
   int digits=(int)SymbolInfoInteger(pair, SYMBOL_DIGITS);
   double Human = MathPow(10, digits);
   spread = spread / Human;
   
   double candle_low = 0;
   double candle_high = 0;
   
   if (trade_type == OP_SELL){
      candle_low = iLow(pair, timeframe, shift) - (slippage_points/Human);
      candle_high = iHigh(pair, timeframe, shift) + (slippage_points/Human);
   }
   
   if (trade_type == OP_BUY){
      candle_low = iLow(pair, timeframe, shift) - (slippage_points/Human);
      candle_high = iHigh(pair, timeframe, shift) + spread + (slippage_points/Human);
   }
   return entry_price >= candle_low && entry_price <= candle_high;
}

void load_bars(string pair, int timeframe, int target){
   score_busy = true;
   int _hwnd = WindowHandle(pair, timeframe);
   int LeftBar = WindowFirstVisibleBar();
   
   datetime last_time = iTime(pair, timeframe, 0);
   for(int i=0;i<200;i++){
      PostMessageA(_hwnd, WM_KEYDOWN, 36, 0);//36=Home
      PostMessageA(_hwnd, WM_KEYUP, 36, 0);
      Sleep(50);
      if(WindowFirstVisibleBar() > target) break;
      // AutoScroll Check
      if(LeftBar > WindowFirstVisibleBar() ){
         PostMessageA(_hwnd, WM_COMMAND, 33017, 0);
         Comment("Uncheck AutoScroll");
         Sleep(50);
      }
      LeftBar = WindowFirstVisibleBar(); 
      if (last_time == iTime(pair, timeframe, 0)) {
         Print("Loaded up so far: ", last_time);
         return;
      }
   }
   Print("Finished loading");
}

int GetGranularity(string pair, datetime date, int precision, int tshift){
   //Print("Getting granularity ..." , precision);
   int timeframe = precision;
   // Hours ahead Guatemala
   int shift = iBarShift(pair,timeframe,date + tshift, true);
   datetime initial_time = iTime(pair,timeframe,shift) - tshift;
   
   if (initial_time < date && shift > 0)
      return timeframe;
   
   if (precision == PERIOD_M5)
      return GetGranularity(pair, date, PERIOD_M5, tshift);
         
   if (precision == PERIOD_M5)
      return GetGranularity(pair, date, PERIOD_M15, tshift);
      
   if (precision == PERIOD_M15)
      return GetGranularity(pair, date, PERIOD_M30, tshift);

   if (precision == PERIOD_M30)
      return GetGranularity(pair, date, PERIOD_H1, tshift);
      
   if (precision == PERIOD_H1)
      return GetGranularity(pair, date, PERIOD_H4, tshift);
      
   if (precision == PERIOD_H4)
      return GetGranularity(pair, date, PERIOD_D1, tshift);

   return NULL;
}

ScoreResult* scoreFxSignal(FxSignal *r){
   if (!r){
      Print("not scoring");
      return NULL;
   }
   
   int digits=(int)SymbolInfoInteger(r.pair, SYMBOL_DIGITS);
   double Human = MathPow(10, digits-1);
   
   // Hours ahead Guatemala
   //int hours = 6; //((int)(TimeGMT() - TimeCurrent())/3600) + 6;
   int tshift = 8*60*60;
   if (StringCompare(AccountCompany(), "SimpleFX Ltd.") == 0)
      tshift = 6*60*60;
   if (StringCompare(AccountCompany(), "FxPro Financial Services Ltd") == 0)
      tshift = 8*60*60;
   if (StringCompare(AccountCompany(), "FXTM FT Global Ltd.") == 0)
      tshift = 8*60*60;
   if (StringCompare(AccountCompany(), "Trading Point Of Financial Instruments Ltd") == 0)
      tshift = 8*60*60;
   
   int timeframe = GetGranularity(r.pair, r.date, PRECISION, tshift);
   if (timeframe == 0 && r.pair=="XAUUSD") {
      int alt = GetGranularity("GOLD", r.date, PRECISION, tshift) > 0;
      if (alt > 0)
         timeframe = alt;
   }
   //Print("Hours ",hours," should be ",6," GMT: ", TimeToStr(TimeGMT()), " Current: ", TimeToStr(TimeCurrent()));
   
   int shift = iBarShift(r.pair,timeframe,r.date + tshift, true);
   //Print("Initial Shift @ ", shift, " ie ", TimeToStr(iTime(r.pair,timeframe,shift) - tshift));
   // If initial date is after date.. try larger precision
   
   
   // Look from shift to shift - 1
   int lookahead = shift - 1;
   
   bool SLHIT = false;
   bool TPHIT = false;
   bool ENTRYHIT = is_price_executed_within(r.pair, timeframe, shift, r.entry, r.sign, ENTRY_SLIPPAGE);
   
   datetime execution_date = NULL;
   if (ENTRYHIT) {
      execution_date = iTime(r.pair,timeframe,shift) - tshift;
   }
   datetime exit_date = NULL;
   
   // lookahead is the cursor or pointer when going back in history
   while (lookahead > 0 && !SLHIT && !TPHIT) {
      
      if (!ENTRYHIT) {
          ENTRYHIT = is_price_executed_within(r.pair, timeframe, lookahead, r.entry, r.sign, ENTRY_SLIPPAGE);
          if (ENTRYHIT) {
            //Print("Execution Date @ Shift: ", lookahead, " ... ,",TimeToStr(iTime(r.pair, timeframe, lookahead)));
            execution_date = iTime(r.pair, timeframe, lookahead) - tshift; 
          } 
      } else {
         //entry not hit yet...
         
      }
      
      if (r.sign == OP_SELL){
         if (iHigh(r.pair, timeframe, lookahead) > r.sl) {
            SLHIT = true; 
            exit_date = iTime(r.pair,timeframe,lookahead) - tshift; 
         }
         else if (iLow(r.pair, timeframe, lookahead) < r.tp){
            TPHIT = true; 
            exit_date = iTime(r.pair,timeframe,lookahead) - tshift; 
         }
      }
      
      if (r.sign == OP_BUY){
         if (iLow(r.pair, timeframe, lookahead) < r.sl) {
            SLHIT = true; 
            exit_date = iTime(r.pair,timeframe,lookahead) - tshift; 
         }
         else if (iHigh(r.pair, timeframe, lookahead) > r.tp){
            TPHIT = true;
            exit_date = iTime(r.pair,timeframe,lookahead) - tshift;
         }
      }
      lookahead--;
   }
   
   datetime last_checked = iTime(r.pair, timeframe, lookahead+1) - tshift;
   datetime last_available = iTime(r.pair, timeframe, 0) - tshift;
      
   if (lookahead < 0 || last_available < r.date) {
         
      load_bars(r.pair,timeframe,Bars);
      datetime _last_available = iTime(r.pair, timeframe, 0) - tshift;
      
      //}
   }  
   string ev = "";
   char st = '-';
   
   if (ENTRYHIT){
      if (TPHIT) {
         ev = "tp_hit";
         st = 'C'; 
      } else if (SLHIT){
         ev = "sl_hit";
         st = 'C';
      } else {
         ev = "open";
         st = 'O';
      }
   } else {
      if (execution_date == NULL){
         st = 'P';
      }
      
      if (TPHIT) {
         ev = "invalid_tp_hit";
         st = 'I';
      } else if (SLHIT) {
         ev = "invalid_sl_hit";
         st = 'I';
      } else {
         ev = "pending";
         st = 'P';
      }
   }
   
   int exec_seconds = (int)execution_date - (int)r.date;
   
   if (exec_seconds > MAX_PENDING_LIFE)
      st = 'E';
   
   if (st == '-' && exec_seconds < timeframe * -60 && execution_date != NULL) {
      Print("Execution date NULL");
      st = 'R'; 
   }
   
   if (st == '-' && timeframe == NULL) {
      Print("Timeframe NULL");
      ev = "recheck";
      st = 'R'; 
   }
   
   return new ScoreResult(r.hash, r.date, execution_date, exit_date, ev, r.username, r.pair, st, last_checked, last_available, timeframe, r);
}


double possize(FxSignal *r, string acc_currency, double acc_balance, double risk){
   double pipvalue = pipvalue(r, acc_currency);
   int digits = (int)MarketInfo(r.pair, MODE_DIGITS); 
   int Human = (int)MathPow(10,digits-1);
   double slpips = MathAbs(r.entry-r.sl)*Human;
      
   double max_loss = risk*acc_balance;
   if (pipvalue<=0)
      return -1;
      
   double max_psize = max_loss/(slpips*pipvalue);
   return StringToDouble(DoubleToStr(max_psize,2));
}

double currency_quote(string base, string counter){
   if (StringCompare(base, counter)==0)
      return 1;
      
   if (MarketInfo(base+counter, MODE_BID)>0){
      return MarketInfo(base+counter, MODE_BID);
   }
   
   if (MarketInfo(counter+base, MODE_BID)>0){
      return MarketInfo(counter+base, MODE_BID);
   }
   
   return NULL;
}

double pipvalue(FxSignal *r, string acc_currency){
   if (StringCompare(acc_currency,"USC")==0)
      acc_currency = "USD";
   int digits = (int)MarketInfo(r.pair, MODE_DIGITS); 
   if ((!digits) && (StringCompare("XAUUSD",r.pair)==0))
      r.pair = "GOLD";
      digits = (int)MarketInfo(r.pair, MODE_DIGITS);
   
   int Human = (int)MathPow(10,digits-1);
   
   if (Human==0){
      Print("Error pipvalue: Human is 0 with "+r.pair," -- ",r);
   }
   double Price = (double)MarketInfo(r.pair,MODE_BID);
   
   string counter = StringSubstr(r.pair,3,3);
   string base = StringSubstr(r.pair,0,3);
   
   if (StringCompare("XAUUSD",r.pair)==0)
     Human *= 1000;
     
   if (StringCompare("BTCUSD",r.pair)==0)
     Human *= 1000;
         
   // PAIR'S COUNTER IS CURRENCY ACCOUNT.
   if (StringCompare(counter, acc_currency)==0){
      return 1.0/Human*100000;
   }
   
   // 1. PAIR's BASE PIP VALUE
   if (StringCompare(DoubleToStr(Price,2),"0.00")==0){
      Alert("Price: 0 - " + r.pair);
      return 0;
   }
   double pipvalue_in_base = (1.0/Human)/Price*100000;
   double base_in_usd = currency_quote(base, "USD");
   
   if (base_in_usd == NULL)
      return -1; 
   
   double pipvalue_in_usd = pipvalue_in_base*base_in_usd;

   if (StringCompare(acc_currency,"BIT")==0){
      if (!(SymbolSelect("BTCUSD",true)))
         return -1;
      else 
          return pipvalue_in_usd/MarketInfo("BTCUSD", MODE_BID)*1000000;
   }
   
   if (StringCompare(acc_currency,"EIT")==0){
      if (!(SymbolSelect("ETHUSD",true)))
         return -1;
      else 
          return pipvalue_in_usd/MarketInfo("ETHUSD", MODE_BID)*1000000;
   }
   
   double usd_in_account = currency_quote("USD", acc_currency);

   if (usd_in_account>0)
      return pipvalue_in_usd*usd_in_account;
      
   return -1;
}

string LAST_TRADE_ERROR = "";

int Open_Trade(string symbol, int op, double lots, double entry, double sl, double tp, string name, long hash, int slippage = 10){
   string _op = "";
   if (op == OP_BUY)
      _op = "BUY MARKET";
   if (op == OP_BUYSTOP)
      _op = "BUY STOP";
   if (op == OP_BUYLIMIT)
      _op = "BUY LIMIT";
   if (op == OP_SELL)
      _op = "SELL MARKET";
   if (op == OP_SELLSTOP)
      _op = "SELL STOP";
   if (op == OP_SELLLIMIT)
      _op = "SELL LIMIT";   
      
   Print("OPENING ",_op," POSITION ",lots," lots");
   
   if (AccountFreeMargin() < lots*1000){
      Print("We have no money. Free Margin = " + DoubleToString(AccountFreeMargin(),2));
      return 0;
   }
   
   ResetLastError();
   string comment = name;
   int magic = (int)hash;
   datetime expiration = TimeCurrent() + 3600*24*10; // 10 days
   
   int color_ = C'255,161,0';    // Orange;
   int ticket = OrderSend(symbol, op, lots, entry, slippage, sl, tp, comment, magic, expiration, color_);
   
   int err = GetLastError(); LAST_TRADE_ERROR = IntegerToString(err);             
   if (err != 4000) {
      Print("GetLastError(): ", LAST_TRADE_ERROR);
   } else {
      if (err == ERR_INVALID_TRADE_VOLUME)
         LAST_TRADE_ERROR = "ERR_INVALID_TRADE_VOLUME";
      if (err == 131)
         LAST_TRADE_ERROR = "ERR_INVALID_TRADE_VOLUME: " + DoubleToStr(lots);
      if (StringCompare(LAST_TRADE_ERROR,"")==0)
         LAST_TRADE_ERROR = " ERROR CODE: " + IntegerToString(err);
   }
   
   Print(LAST_TRADE_ERROR);

   string str;
   
   if (ticket > 0) {
      bool selected = OrderSelect(ticket, SELECT_BY_TICKET);
      if (selected)
         str = symbol + ": " + _op + " opened " + DoubleToStr(OrderLots(),2) + " @ " + DoubleToStr(OrderOpenPrice(),5);
      else
         str = "Error selecting ticket: " + IntegerToString(ticket);
   } else {
      str = symbol + ": " +  _op + ": " + LAST_TRADE_ERROR;
   }
   
   Print("Sending error message: " + str); 
   Print(symbol, str);
             
   return ticket;
}

int Open_BuyMarket(string TheSymbol, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_BUY, LotsAmount, MarketInfo(TheSymbol, MODE_ASK), SL, TP, name, hash);
}

int Open_SellMarket(string TheSymbol, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_SELL, LotsAmount, MarketInfo(TheSymbol, MODE_BID), SL, TP, name, hash);
}

int Open_BuyLimit(string TheSymbol, double Entry, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_BUYLIMIT, LotsAmount, Entry, SL, TP, name, hash);
}

int Open_SellLimit(string TheSymbol, double Entry, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_SELLLIMIT, LotsAmount, Entry, SL, TP, name, hash);
}

int Open_BuyStop(string TheSymbol, double Entry, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_BUYSTOP, LotsAmount, Entry, SL, TP, name, hash);
}

int Open_SellStop(string TheSymbol, double Entry, double TP, double SL, double LotsAmount, string name, long hash){
   return Open_Trade(TheSymbol, OP_SELLSTOP, LotsAmount, Entry, SL, TP, name, hash);
}

int Execute_Trade(FxSignal *r, double riskpct) {
   string str;
   string acc_currency = AccountInfoString(ACCOUNT_CURRENCY);
   double acc_balance = AccountBalance();
   
   double psize=possize(r, acc_currency, acc_balance, riskpct/100);
   if (psize<=0) {
      return -1;
   }
   
   if (!(psize > 0.01)){
      Print("Warning: ",DoubleToStr(psize),"too small");
      return -1;
   }
   
   int digits = (int)MarketInfo(r.pair, MODE_DIGITS);
   int ticket = 0;
    
   string slippage_hint = "";
   int Human = (int)MathPow(10,digits-1);
   bool MakeTheTrade = true;
      
   if (r.sign == OP_SELL){
      double Price = MarketInfo(r.pair,MODE_BID);
      double Distance = (Price - r.entry)*Human;
      if (MathAbs(Distance) <= 10) {
         slippage_hint = " NOW ";
         if (MakeTheTrade)
            ticket = Open_SellMarket(r.pair, r.tp, r.sl, psize, r.username, r.hash);
      }
      else {
         Print("Distance between price ",  Price," and entry ", r.entry, " is ", Distance);
         if (Distance < 0) 
         {
            slippage_hint = " LIMIT ";
            if (MakeTheTrade)
               ticket = Open_SellLimit(r.pair, r.entry, r.tp, r.sl, psize, r.username, r.hash);
         }
         else {
            slippage_hint = " STOP ";
            if (MakeTheTrade)
               ticket = Open_SellStop(r.pair, r.entry, r.tp, r.sl, psize, r.username, r.hash);
         }
      }
      str += "👇 SELL"+slippage_hint+" 👇";
   }
   if (r.sign == OP_BUY){
      double Price = MarketInfo(r.pair,MODE_ASK);
      double Distance = (r.entry - Price)*Human;
      if (MathAbs(Distance) <= 10) {
         slippage_hint = " NOW ";
         if (MakeTheTrade)
            ticket = Open_BuyMarket(r.pair, r.tp, r.sl, psize, r.username, r.hash);
      }
      else
         if (Distance > 0) {
            slippage_hint = " STOP ";
            if (MakeTheTrade)
               ticket = Open_BuyStop(r.pair, r.entry, r.tp, r.sl, psize, r.username, r.hash);
         } else {
            slippage_hint = " LIMIT ";
            if (MakeTheTrade)
               ticket = Open_BuyLimit(r.pair, r.entry, r.tp, r.sl, psize, r.username, r.hash);
         }
      str +=  "☝ BUY"+slippage_hint+"☝️️";
   }
   
   return ticket;         
}