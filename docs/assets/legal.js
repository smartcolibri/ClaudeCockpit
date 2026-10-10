// Language toggle for the privacy and support pages; shares the landing page's choice.
var LANG_TAG={en:'en',fr:'fr'};
function setLang(l){
  if(!LANG_TAG[l]) l='en';
  document.body.classList.remove('lang-en','lang-fr','lang-zh');
  document.body.classList.add('lang-'+l);
  document.documentElement.lang=LANG_TAG[l];
  document.querySelectorAll('.langtog button').forEach(function(b){
    var on=b.dataset.lang===l;
    b.classList.toggle('on',on);
    b.setAttribute('aria-pressed',on?'true':'false');
  });
  try{localStorage.setItem('vl-lang',l)}catch(e){}
}
(function(){
  var q=new URLSearchParams(location.search).get('lang');
  var saved;try{saved=localStorage.getItem('vl-lang')}catch(e){}
  var n=(navigator.language||'en').slice(0,2).toLowerCase();
  setLang(q||(saved==='fr'||saved==='en'?saved:(n==='fr'?'fr':'en')));
})();
