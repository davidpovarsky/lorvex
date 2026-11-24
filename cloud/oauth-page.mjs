export const htmlEscape=value=>String(value).replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
export const oauthLabels={
 he:{
  title:'התחברות לחשבון Lorvex',intro:'חבר את המשימות, הרשימות, היומן וההרגלים שלך ל־ChatGPT. אין צורך בקוד צימוד או באייפד פתוח.',
  email:'דואר אלקטרוני',password:'סיסמה',passwordHint:'הסיסמה חייבת להכיל 12–256 תווים.',
  login:'התחברות ואישור',register:'יצירת חשבון ואישור',language:'שפת הדף',permissions:'הרשאות מבוקשות',
  read:'קריאת המשימות, הרשימות, היומן וההרגלים שלך',write:'יצירה, עריכה ומחיקה בחשבון שלך',
  offline:'גישה מתמשכת עד לביטול החיבור',footer:'רק חשבון Lorvex זה משותף עם ChatGPT. אפשר לבטל את החיבור בהגדרות ChatGPT.',
  invalid:'ההתחברות לא הושלמה. בדוק את כתובת הדואר האלקטרוני והסיסמה.',
  errorTitle:'ההתחברות לא הושלמה',expired:'החיבור פג תוקף. יש לחזור ל־ChatGPT ולהתחבר מחדש.',
  invalidOrigin:'מקור הבקשה אינו תקין. יש לפתוח מחדש את ההתחברות מתוך ChatGPT.',
  invalidRequest:'בקשת הרשאה לא תקינה. יש לפתוח מחדש את ההתחברות מתוך ChatGPT.',
  rateLimit:'יותר מדי ניסיונות. יש לנסות שוב מאוחר יותר.'
 },
 en:{
  title:'Sign in to Lorvex',intro:'Connect your tasks, lists, calendar and habits to ChatGPT. No pairing code or open iPad is required.',
  email:'Email',password:'Password',passwordHint:'Use 12–256 characters.',
  login:'Sign in and allow',register:'Create account and allow',language:'Page language',permissions:'Requested permissions',
  read:'Read your tasks, lists, calendar and habits',write:'Create, edit and delete content in your account',
  offline:'Keep access until you revoke this connection',footer:'Only this Lorvex account is shared with ChatGPT. You can revoke this connection in ChatGPT settings.',
  invalid:'Sign-in could not be completed. Check your email and password.',
  errorTitle:'Sign-in could not be completed',expired:'Authorization request expired. Return to ChatGPT and connect again.',
  invalidOrigin:'Invalid request origin. Open the connection again from ChatGPT.',
  invalidRequest:'Invalid authorization request. Open the connection again from ChatGPT.',
  rateLimit:'Too many attempts. Please try again later.'
 }
};
const supportedLanguage=value=>/^(en|he)(?:-[a-z0-9]+)*$/i.test(value)?value.slice(0,2).toLowerCase():null;
export function oauthLanguage(uiLocales,acceptLanguage){
 for(const tag of String(uiLocales||'').trim().split(/\s+/)){const language=supportedLanguage(tag);if(language)return language;}
 const preferences=String(acceptLanguage||'').split(',').flatMap((part,index)=>{
  const [range,...parameters]=part.trim().split(/\s*;\s*/);
  const language=range==='*'?'*':supportedLanguage(range);
  const quality=parameters.length?parameters[0].match(/^q=(0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/i):null;
  if(!language||parameters.length>1||(parameters.length&&!quality))return [];
  return [{language,quality:quality?Number(quality[1]):1,index}];
 });
 const candidates=['he','en'].flatMap(language=>{
  const exact=preferences.filter(item=>item.language===language);
  const matches=exact.length?exact:preferences.filter(item=>item.language==='*');
  const best=matches.sort((a,b)=>b.quality-a.quality||a.index-b.index)[0];
  return best?.quality>0?[{...best,language}]:[];
 });
 return candidates.sort((a,b)=>b.quality-a.quality||a.index-b.index)[0]?.language||'he';
}
export const oauthDocument=(language,title,body)=>
 '<!doctype html><html lang="'+language+'" dir="'+(language==='en'?'ltr':'rtl')+'"><head><meta charset="utf-8">'+
 '<meta name="viewport" content="width=device-width, initial-scale=1"><title>'+htmlEscape(title)+'</title>'+
 '<style>body{font:16px system-ui;margin:5vh auto;max-width:480px;padding:24px;color:#20242a;line-height:1.55}'+
 'h1{font-size:26px}input{direction:ltr;text-align:left;display:block;box-sizing:border-box;width:100%;padding:13px;font-size:17px;margin:10px 0;border:1px solid #aaa;border-radius:9px}'+
 'button{padding:14px;background:#2563eb;color:white;border:0;border-radius:9px;font-size:16px;cursor:pointer}'+
 'button+button{margin-inline-start:8px;background:#4b5563}.hint{font-size:14px;color:#555}'+
 '.language{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin-block:18px}.language button[aria-pressed="true"]{outline:2px solid #2563eb;outline-offset:2px}'+
 '</style></head><body>'+body+'</body></html>';
export function oauthLoginBody(request,error=''){
 const language=request.language==='en'?'en':'he',labels=oauthLabels[language],id=htmlEscape(request.id);
 const names={'lorvex.read':labels.read,'lorvex.write':labels.write,offline_access:labels.offline};
 const permissions=request.scopes.split(' ').filter(scope=>names[scope]).map(scope=>'<li>'+names[scope]+'</li>').join('');
 return '<h1>'+labels.title+'</h1><p>'+labels.intro+'</p>'+
  '<form class="language" action="/cloud/oauth/language" method="post"><input type="hidden" name="request" value="'+id+'">'+
  '<span>'+labels.language+'</span><button name="language" value="he" aria-pressed="'+(language==='he')+'">עברית</button>'+
  '<button name="language" value="en" aria-pressed="'+(language==='en')+'">English</button></form>'+
  '<section aria-label="'+labels.permissions+'"><h2>'+labels.permissions+'</h2><ul>'+permissions+'</ul></section>'+
  (error?'<p role="alert">'+labels.invalid+'</p>':'')+
  '<form action="/cloud/oauth/approve" method="post"><input type="hidden" name="request" value="'+id+'">'+
  '<label>'+labels.email+'<input type="email" name="email" autocomplete="username" maxlength="250" required></label>'+
  '<label>'+labels.password+'<input type="password" name="password" autocomplete="current-password" minlength="12" maxlength="256" aria-describedby="password-hint" required></label>'+
  '<p class="hint" id="password-hint">'+labels.passwordHint+'</p>'+
  '<button name="mode" value="login" type="submit">'+labels.login+'</button>'+
  '<button name="mode" value="register" type="submit">'+labels.register+'</button>'+
  '</form><p class="hint">'+labels.footer+'</p>';
}
