/// The app's own text in other languages — see l10n/app_strings.dart for how
/// it's used.
///
/// Each table maps the English text exactly as it appears in the code to its
/// translation. A missing line is not a problem: the app simply shows the
/// English for it. To add a language, add one more table below, list it in
/// [appTranslations], and it shows up as "App text" in Settings > App language.
/// To translate more of the app, wrap its text in `context.tr('...')` and add
/// the line to each table.
///
/// These were written with machine help and would benefit from a read-through
/// by a native speaker of each language.
const Map<String, Map<String, String>> appTranslations = {
  'hi': _hi,
  'ml': _ml,
  'ar': _ar,
  'es': _es,
  'fr': _fr,
  'pt': _pt,
};

// Hindi
const Map<String, String> _hi = {
  'What gets included':
      'क्या शामिल होगा',
  'Nothing could be read from this phone.':
      'इस फ़ोन से कुछ पढ़ा नहीं जा सका।',
  'Close':
      'बंद करें',
  'Please write a short subject.':
      'कृपया एक छोटा विषय लिखें।',
  'Please describe the problem in a few words.':
      'कृपया समस्या को कुछ शब्दों में बताएँ।',
  'No email app found':
      'कोई ईमेल ऐप नहीं मिला',
  'Your report was copied. Paste it into an email to':
      'आपकी रिपोर्ट कॉपी हो गई है। इसे ईमेल में पेस्ट करके इस पते पर भेजें:',
  'OK':
      'ठीक है',
  'Your email app opened. Just press send.':
      'आपका ईमेल ऐप खुल गया है। बस भेजें दबाएँ।',
  'Report a problem':
      'समस्या की रिपोर्ट करें',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'बताइए क्या गड़बड़ हुई। आपका ईमेल ऐप आपके संदेश और तकनीकी जानकारी के साथ खुलेगा — आपको बस भेजें दबाना है।',
  'App bug':
      'ऐप बग',
  'Security problem':
      'सुरक्षा समस्या',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'कृपया पासवर्ड, PIN या प्राइवेट की शामिल न करें। ईमेल एंड-टू-एंड एन्क्रिप्टेड नहीं होता, इसलिए समस्या को गोपनीय जानकारी के बिना समझाएँ।',
  'Subject':
      'विषय',
  'Describe the security problem':
      'सुरक्षा समस्या का वर्णन करें',
  'What happened?':
      'क्या हुआ?',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      'कोई क्या कर सकता है, और कैसे? समस्या दोहराने के चरण बहुत मदद करते हैं।',
  'What did you do, what did you expect, and what happened instead?':
      'आपने क्या किया, आप क्या उम्मीद कर रहे थे, और इसके बजाय क्या हुआ?',
  'Include phone and app details':
      'फ़ोन और ऐप की जानकारी शामिल करें',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'फ़ोन मॉडल, Android और ऐप वर्शन, बैटरी, स्टोरेज, नेटवर्क का प्रकार और इसी तरह की जानकारी। आपके संदेश, संपर्क, फ़ोन नंबर, खाते की जानकारी, लोकेशन या IP पता कभी शामिल नहीं होते।',
  'See exactly what is included':
      'देखें कि ठीक-ठीक क्या शामिल है',
  'Include the crash details':
      'क्रैश की जानकारी शामिल करें',
  'Include recent error details':
      'हाल की त्रुटियों की जानकारी शामिल करें',
  'Technical error information from this app, which helps find the cause.':
      'इस ऐप की तकनीकी त्रुटि जानकारी, जो कारण खोजने में मदद करती है।',
  'Send report':
      'रिपोर्ट भेजें',
  'Goes to':
      'भेजा जाएगा:',
  'Protect your IP address?':
      'अपना IP पता सुरक्षित रखें?',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'आपकी कॉल एक रिले सर्वर से होकर जाएँगी ताकि दूसरा व्यक्ति आपका IP पता न देख सके।\n\nऑडियो को लंबा रास्ता तय करना पड़ता है, इसलिए कॉल में देरी हो सकती है, आवाज़ की गुणवत्ता कम हो सकती है और ज़्यादा मोबाइल डेटा लग सकता है। अगर कॉल कनेक्ट न हो, तो यहाँ आकर इसे बंद कर दें।',
  'Cancel':
      'रद्द करें',
  'Turn on':
      'चालू करें',
  'Calls':
      'कॉल',
  'Protect IP address in calls':
      'कॉल में IP पता सुरक्षित रखें',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'कॉल को सर्वर से रिले करें ताकि दूसरा व्यक्ति आपका IP पता न देख सके। इससे कॉल की गुणवत्ता घटती है।',
  'Not available in this version of the app — it has no relay server set up.':
      'ऐप के इस वर्शन में उपलब्ध नहीं — इसमें रिले सर्वर सेट नहीं है।',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'चालू — आपकी कॉल रिले हो रही हैं। अगर कॉल कनेक्ट न हो या आवाज़ खराब हो, तो इसे बंद करके देखें।',
  'App language':
      'ऐप की भाषा',
  'Search languages':
      'भाषाएँ खोजें',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      '"ऐप टेक्स्ट" वाली भाषाओं का अनुवाद पूरे ऐप में है। बाकी भाषाओं में सिस्टम वाले हिस्से (तारीख़ चुनने वाले, डायलॉग बटन, लिखने की दिशा) बदल जाते हैं और बाकी अभी अंग्रेज़ी में रहता है।',
  'Use the same language as your phone':
      'अपने फ़ोन वाली भाषा ही इस्तेमाल करें',
  'App text':
      'ऐप टेक्स्ट',
  'Menus and dialogs':
      'मेनू और डायलॉग',
  'No language found':
      'कोई भाषा नहीं मिली',
  'NWisp closed unexpectedly':
      'NWisp अचानक बंद हो गया',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'लगता है NWisp पिछली बार क्रैश हो गया था। क्या आप रिपोर्ट भेजना चाहेंगे ताकि इसे ठीक किया जा सके? आपका ईमेल ऐप जानकारी भरकर खुलेगा — आपको बस भेजें दबाना है।',
  'Not now':
      'अभी नहीं',
  'Settings':
      'सेटिंग्स',
  'Edit Profile':
      'प्रोफ़ाइल संपादित करें',
  'Log out':
      'लॉग आउट',
  'Privacy checkup':
      'प्राइवेसी चेकअप',
  'Check your privacy settings and turn them all on in one tap':
      'अपनी प्राइवेसी सेटिंग्स जाँचें और एक टैप में सब चालू करें',
  'Account':
      'खाता',
  'Email, password, account security':
      'ईमेल, पासवर्ड, खाते की सुरक्षा',
  'Privacy':
      'प्राइवेसी',
  'Last seen, read receipts, blocked users':
      'अंतिम बार देखा गया, रीड रसीदें, ब्लॉक किए गए लोग',
  'Security':
      'सुरक्षा',
  'App lock, biometrics, panic PIN, chat hiding':
      'ऐप लॉक, बायोमेट्रिक्स, पैनिक PIN, चैट छिपाना',
  'Encryption & quantum safety':
      'एन्क्रिप्शन और क्वांटम सुरक्षा',
  'Post-quantum protection, strict mode':
      'पोस्ट-क्वांटम सुरक्षा, सख़्त मोड',
  'Private browser':
      'प्राइवेट ब्राउज़र',
  'In-app browser, tracker blocking, search engine':
      'ऐप के अंदर ब्राउज़र, ट्रैकर ब्लॉकिंग, सर्च इंजन',
  'Login activity':
      'लॉगिन गतिविधि',
  'Devices and sign-ins on your account':
      'आपके खाते के डिवाइस और साइन-इन',
  'Full-screen call alerts':
      'फ़ुल-स्क्रीन कॉल अलर्ट',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'NWisp बंद होने पर भी आने वाली कॉल लॉक स्क्रीन पर बजें',
  'Broadcast lists':
      'ब्रॉडकास्ट सूचियाँ',
  'Send one message to many people':
      'एक संदेश कई लोगों को भेजें',
  'Chat folders':
      'चैट फ़ोल्डर',
  'Organise your chats':
      'अपनी चैट व्यवस्थित करें',
  'Note to self':
      'खुद के लिए नोट',
  'A private notepad on this phone':
      'इस फ़ोन पर एक निजी नोटपैड',
  'Scheduled messages':
      'शेड्यूल किए गए संदेश',
  'Messages waiting to be sent':
      'भेजे जाने की प्रतीक्षा में संदेश',
  'Starred messages':
      'तारांकित संदेश',
  'Messages you starred':
      'जिन संदेशों पर आपने तारा लगाया',
  'Media vault':
      'मीडिया वॉल्ट',
  'Locked photos and videos':
      'लॉक किए गए फ़ोटो और वीडियो',
  'Protect your IP address in calls':
      'कॉल में अपना IP पता सुरक्षित रखें',
  'Notifications':
      'सूचनाएँ',
  'Muted keywords':
      'म्यूट किए गए कीवर्ड',
  'Chats':
      'चैट',
  'Auto-delete, paused chats, home screen layout':
      'ऑटो-डिलीट, रोकी गई चैट, होम स्क्रीन लेआउट',
  'Appearance':
      'दिखावट',
  'Customize how the app looks on this device':
      'तय करें कि इस डिवाइस पर ऐप कैसा दिखे',
  'Report a bug or a security problem':
      'बग या सुरक्षा समस्या की रिपोर्ट करें',
  'Help & About':
      'सहायता और जानकारी',
  'Help centre, legal, feature guide':
      'सहायता केंद्र, कानूनी, फ़ीचर गाइड',
  'Stories':
      'स्टोरीज़',
  'Announcements':
      'घोषणाएँ',
  'Community':
      'कम्युनिटी',
  'Phone language':
      'फ़ोन की भाषा',
  'Nearby':
      'आस-पास',
  'Low-data mode':
      'कम डेटा मोड',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'वॉइस कॉल पर लगभग आधा डेटा इस्तेमाल होता है (करीब 0.12 MB प्रति मिनट)। आवाज़ थोड़ी पतली लगती है। कमज़ोर या महँगे कनेक्शन के लिए अच्छा।',
  'Recording alerts':
      'रिकॉर्डिंग अलर्ट',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'अगर कॉल के दौरान इस फ़ोन का कोई दूसरा ऐप आवाज़ रिकॉर्ड करना शुरू करे, तो दूसरे व्यक्ति को बताएँ। जब उनका फ़ोन रिकॉर्ड करे तो आपको हमेशा चेतावनी मिलती है। यह किसी दूसरे डिवाइस पर हो रही रिकॉर्डिंग नहीं पकड़ सकता।',
  'Bots':
      'बॉट',
  'Create and manage your bots, or open one':
      'अपने बॉट बनाएँ और प्रबंधित करें, या कोई बॉट खोलें',
};

// Malayalam
const Map<String, String> _ml = {
  'What gets included':
      'എന്തെല്ലാം ഉൾപ്പെടും',
  'Nothing could be read from this phone.':
      'ഈ ഫോണിൽ നിന്ന് ഒന്നും വായിക്കാനായില്ല.',
  'Close':
      'അടയ്ക്കുക',
  'Please write a short subject.':
      'ദയവായി ഒരു ചെറിയ വിഷയം എഴുതുക.',
  'Please describe the problem in a few words.':
      'ദയവായി പ്രശ്നം ഏതാനും വാക്കുകളിൽ വിവരിക്കുക.',
  'No email app found':
      'ഇമെയിൽ ആപ്പ് കണ്ടെത്തിയില്ല',
  'Your report was copied. Paste it into an email to':
      'നിങ്ങളുടെ റിപ്പോർട്ട് പകർത്തി. ഇത് ഒരു ഇമെയിലിൽ ഒട്ടിച്ച് ഈ വിലാസത്തിലേക്ക് അയയ്ക്കുക:',
  'OK':
      'ശരി',
  'Your email app opened. Just press send.':
      'നിങ്ങളുടെ ഇമെയിൽ ആപ്പ് തുറന്നു. അയയ്ക്കുക അമർത്തിയാൽ മതി.',
  'Report a problem':
      'പ്രശ്നം റിപ്പോർട്ട് ചെയ്യുക',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'എന്താണ് തകരാറായതെന്ന് പറയൂ. നിങ്ങളുടെ സന്ദേശവും സാങ്കേതിക വിവരങ്ങളും നിറച്ച് ഇമെയിൽ ആപ്പ് തുറക്കും — നിങ്ങൾ അയയ്ക്കുക അമർത്തിയാൽ മതി.',
  'App bug':
      'ആപ്പ് ബഗ്',
  'Security problem':
      'സുരക്ഷാ പ്രശ്നം',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'പാസ്‌വേഡുകൾ, PIN, പ്രൈവറ്റ് കീകൾ എന്നിവ ഉൾപ്പെടുത്തരുത്. ഇമെയിൽ എൻഡ്-ടു-എൻഡ് എൻക്രിപ്റ്റഡ് അല്ല, അതിനാൽ രഹസ്യം ഒഴിവാക്കി പ്രശ്നം വിവരിക്കുക.',
  'Subject':
      'വിഷയം',
  'Describe the security problem':
      'സുരക്ഷാ പ്രശ്നം വിവരിക്കുക',
  'What happened?':
      'എന്താണ് സംഭവിച്ചത്?',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      'ആർക്ക് എന്ത് ചെയ്യാനാകും, എങ്ങനെ? പ്രശ്നം ആവർത്തിക്കാനുള്ള ഘട്ടങ്ങൾ വളരെ സഹായിക്കും.',
  'What did you do, what did you expect, and what happened instead?':
      'നിങ്ങൾ എന്ത് ചെയ്തു, എന്ത് പ്രതീക്ഷിച്ചു, പകരം എന്ത് സംഭവിച്ചു?',
  'Include phone and app details':
      'ഫോൺ, ആപ്പ് വിവരങ്ങൾ ഉൾപ്പെടുത്തുക',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'ഫോൺ മോഡൽ, Android, ആപ്പ് പതിപ്പ്, ബാറ്ററി, സ്റ്റോറേജ്, നെറ്റ്‌വർക്ക് തരം എന്നിവയും സമാന വിവരങ്ങളും. നിങ്ങളുടെ സന്ദേശങ്ങൾ, കോൺടാക്റ്റുകൾ, ഫോൺ നമ്പർ, അക്കൗണ്ട് വിവരങ്ങൾ, ലൊക്കേഷൻ, IP വിലാസം എന്നിവ ഒരിക്കലും ഉൾപ്പെടില്ല.',
  'See exactly what is included':
      'കൃത്യമായി എന്തെല്ലാം ഉൾപ്പെടുന്നുവെന്ന് കാണുക',
  'Include the crash details':
      'ക്രാഷ് വിവരങ്ങൾ ഉൾപ്പെടുത്തുക',
  'Include recent error details':
      'സമീപകാല പിശക് വിവരങ്ങൾ ഉൾപ്പെടുത്തുക',
  'Technical error information from this app, which helps find the cause.':
      'ഈ ആപ്പിലെ സാങ്കേതിക പിശക് വിവരങ്ങൾ, കാരണം കണ്ടെത്താൻ സഹായിക്കും.',
  'Send report':
      'റിപ്പോർട്ട് അയയ്ക്കുക',
  'Goes to':
      'അയയ്ക്കുന്നത്:',
  'Protect your IP address?':
      'നിങ്ങളുടെ IP വിലാസം സംരക്ഷിക്കണോ?',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'മറ്റേയാൾക്ക് നിങ്ങളുടെ IP വിലാസം കാണാനാകാത്ത വിധം നിങ്ങളുടെ കോളുകൾ ഒരു റിലേ സെർവർ വഴി പോകും.\n\nഓഡിയോ കൂടുതൽ ദൂരം സഞ്ചരിക്കുന്നതിനാൽ കോളിൽ കാലതാമസവും ശബ്ദ നിലവാരക്കുറവും ഉണ്ടാകാം, മൊബൈൽ ഡാറ്റയും കൂടുതൽ ഉപയോഗിക്കാം. കോൾ കണക്റ്റ് ആയില്ലെങ്കിൽ ഇവിടെ വന്ന് ഇത് ഓഫ് ചെയ്യുക.',
  'Cancel':
      'റദ്ദാക്കുക',
  'Turn on':
      'ഓൺ ചെയ്യുക',
  'Calls':
      'കോളുകൾ',
  'Protect IP address in calls':
      'കോളുകളിൽ IP വിലാസം സംരക്ഷിക്കുക',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'മറ്റേയാൾക്ക് നിങ്ങളുടെ IP വിലാസം കാണാനാകാത്ത വിധം കോളുകൾ ഒരു സെർവർ വഴി റിലേ ചെയ്യുക. ഇത് കോൾ നിലവാരം കുറയ്ക്കും.',
  'Not available in this version of the app — it has no relay server set up.':
      'ആപ്പിന്റെ ഈ പതിപ്പിൽ ലഭ്യമല്ല — ഇതിൽ റിലേ സെർവർ സജ്ജീകരിച്ചിട്ടില്ല.',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'ഓൺ — നിങ്ങളുടെ കോളുകൾ റിലേ ചെയ്യുന്നു. കോൾ കണക്റ്റ് ആകുന്നില്ലെങ്കിലോ ശബ്ദം മോശമാണെങ്കിലോ ഇത് ഓഫ് ചെയ്ത് നോക്കുക.',
  'App language':
      'ആപ്പ് ഭാഷ',
  'Search languages':
      'ഭാഷകൾ തിരയുക',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      '"ആപ്പ് ടെക്സ്റ്റ്" എന്ന് അടയാളപ്പെടുത്തിയ ഭാഷകൾ ആപ്പിലുടനീളം വിവർത്തനം ചെയ്തിട്ടുണ്ട്. മറ്റുള്ളവയിൽ സിസ്റ്റം ഭാഗങ്ങൾ (തീയതി പിക്കർ, ഡയലോഗ് ബട്ടണുകൾ, എഴുത്തിന്റെ ദിശ) മാറും, ബാക്കി തൽക്കാലം ഇംഗ്ലീഷിൽ തുടരും.',
  'Use the same language as your phone':
      'നിങ്ങളുടെ ഫോണിന്റെ ഭാഷ തന്നെ ഉപയോഗിക്കുക',
  'App text':
      'ആപ്പ് ടെക്സ്റ്റ്',
  'Menus and dialogs':
      'മെനുകളും ഡയലോഗുകളും',
  'No language found':
      'ഭാഷ കണ്ടെത്തിയില്ല',
  'NWisp closed unexpectedly':
      'NWisp അപ്രതീക്ഷിതമായി അടഞ്ഞു',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'കഴിഞ്ഞ തവണ NWisp ക്രാഷ് ആയതായി തോന്നുന്നു. ഇത് പരിഹരിക്കാൻ ഒരു റിപ്പോർട്ട് അയയ്ക്കണോ? വിവരങ്ങൾ നിറച്ച് ഇമെയിൽ ആപ്പ് തുറക്കും — അയയ്ക്കുക അമർത്തിയാൽ മതി.',
  'Not now':
      'ഇപ്പോൾ വേണ്ട',
  'Settings':
      'ക്രമീകരണങ്ങൾ',
  'Edit Profile':
      'പ്രൊഫൈൽ എഡിറ്റ് ചെയ്യുക',
  'Log out':
      'ലോഗ് ഔട്ട്',
  'Privacy checkup':
      'സ്വകാര്യതാ പരിശോധന',
  'Check your privacy settings and turn them all on in one tap':
      'നിങ്ങളുടെ സ്വകാര്യതാ ക്രമീകരണങ്ങൾ പരിശോധിച്ച് ഒറ്റ ടാപ്പിൽ എല്ലാം ഓൺ ചെയ്യുക',
  'Account':
      'അക്കൗണ്ട്',
  'Email, password, account security':
      'ഇമെയിൽ, പാസ്‌വേഡ്, അക്കൗണ്ട് സുരക്ഷ',
  'Privacy':
      'സ്വകാര്യത',
  'Last seen, read receipts, blocked users':
      'അവസാനം കണ്ടത്, റീഡ് രസീതുകൾ, ബ്ലോക്ക് ചെയ്തവർ',
  'Security':
      'സുരക്ഷ',
  'App lock, biometrics, panic PIN, chat hiding':
      'ആപ്പ് ലോക്ക്, ബയോമെട്രിക്സ്, പാനിക് PIN, ചാറ്റ് മറയ്ക്കൽ',
  'Encryption & quantum safety':
      'എൻക്രിപ്ഷനും ക്വാണ്ടം സുരക്ഷയും',
  'Post-quantum protection, strict mode':
      'പോസ്റ്റ്-ക്വാണ്ടം സംരക്ഷണം, കർശന മോഡ്',
  'Private browser':
      'പ്രൈവറ്റ് ബ്രൗസർ',
  'In-app browser, tracker blocking, search engine':
      'ആപ്പിനുള്ളിലെ ബ്രൗസർ, ട്രാക്കർ തടയൽ, സെർച്ച് എൻജിൻ',
  'Login activity':
      'ലോഗിൻ പ്രവർത്തനം',
  'Devices and sign-ins on your account':
      'നിങ്ങളുടെ അക്കൗണ്ടിലെ ഉപകരണങ്ങളും സൈൻ-ഇന്നുകളും',
  'Full-screen call alerts':
      'ഫുൾ-സ്ക്രീൻ കോൾ അലേർട്ടുകൾ',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'NWisp അടച്ചിരിക്കുമ്പോഴും വരുന്ന കോളുകൾ ലോക്ക് സ്ക്രീനിൽ റിംഗ് ചെയ്യാൻ അനുവദിക്കുന്നു',
  'Broadcast lists':
      'ബ്രോഡ്കാസ്റ്റ് ലിസ്റ്റുകൾ',
  'Send one message to many people':
      'ഒരു സന്ദേശം പലർക്കും അയയ്ക്കുക',
  'Chat folders':
      'ചാറ്റ് ഫോൾഡറുകൾ',
  'Organise your chats':
      'നിങ്ങളുടെ ചാറ്റുകൾ ക്രമീകരിക്കുക',
  'Note to self':
      'എനിക്കുള്ള കുറിപ്പ്',
  'A private notepad on this phone':
      'ഈ ഫോണിലെ ഒരു സ്വകാര്യ നോട്ട്പാഡ്',
  'Scheduled messages':
      'ഷെഡ്യൂൾ ചെയ്ത സന്ദേശങ്ങൾ',
  'Messages waiting to be sent':
      'അയയ്ക്കാൻ കാത്തിരിക്കുന്ന സന്ദേശങ്ങൾ',
  'Starred messages':
      'നക്ഷത്രമിട്ട സന്ദേശങ്ങൾ',
  'Messages you starred':
      'നിങ്ങൾ നക്ഷത്രമിട്ട സന്ദേശങ്ങൾ',
  'Media vault':
      'മീഡിയ വോൾട്ട്',
  'Locked photos and videos':
      'ലോക്ക് ചെയ്ത ഫോട്ടോകളും വീഡിയോകളും',
  'Protect your IP address in calls':
      'കോളുകളിൽ നിങ്ങളുടെ IP വിലാസം സംരക്ഷിക്കുക',
  'Notifications':
      'അറിയിപ്പുകൾ',
  'Muted keywords':
      'മ്യൂട്ട് ചെയ്ത കീവേഡുകൾ',
  'Chats':
      'ചാറ്റുകൾ',
  'Auto-delete, paused chats, home screen layout':
      'ഓട്ടോ-ഡിലീറ്റ്, താൽക്കാലികമായി നിർത്തിയ ചാറ്റുകൾ, ഹോം സ്ക്രീൻ ലേഔട്ട്',
  'Appearance':
      'രൂപഭാവം',
  'Customize how the app looks on this device':
      'ഈ ഉപകരണത്തിൽ ആപ്പ് എങ്ങനെ കാണപ്പെടണമെന്ന് ക്രമീകരിക്കുക',
  'Report a bug or a security problem':
      'ബഗ്ഗോ സുരക്ഷാ പ്രശ്നമോ റിപ്പോർട്ട് ചെയ്യുക',
  'Help & About':
      'സഹായവും വിവരങ്ങളും',
  'Help centre, legal, feature guide':
      'സഹായ കേന്ദ്രം, നിയമപരം, ഫീച്ചർ ഗൈഡ്',
  'Stories':
      'സ്റ്റോറികൾ',
  'Announcements':
      'പ്രഖ്യാപനങ്ങൾ',
  'Community':
      'കമ്മ്യൂണിറ്റി',
  'Phone language':
      'ഫോണിന്റെ ഭാഷ',
  'Nearby':
      'സമീപത്ത്',
  'Low-data mode':
      'കുറഞ്ഞ ഡാറ്റ മോഡ്',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'വോയ്‌സ് കോളുകളിൽ ഏകദേശം പകുതി ഡാറ്റ മതി (മിനിറ്റിന് ഏകദേശം 0.12 MB). ശബ്ദം അല്പം നേർത്തതായി തോന്നാം. ദുർബലമോ ചെലവേറിയതോ ആയ കണക്ഷന് നല്ലത്.',
  'Recording alerts':
      'റെക്കോർഡിംഗ് അലേർട്ടുകൾ',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'കോളിനിടെ ഈ ഫോണിലെ മറ്റൊരു ആപ്പ് ശബ്ദം റെക്കോർഡ് ചെയ്യാൻ തുടങ്ങിയാൽ മറ്റേയാളെ അറിയിക്കുക. അവരുടെ ഫോൺ റെക്കോർഡ് ചെയ്താൽ നിങ്ങൾക്ക് എപ്പോഴും മുന്നറിയിപ്പ് ലഭിക്കും. മറ്റൊരു ഉപകരണത്തിൽ നടക്കുന്ന റെക്കോർഡിംഗ് ഇത് കണ്ടെത്തില്ല.',
  'Bots':
      'ബോട്ടുകൾ',
  'Create and manage your bots, or open one':
      'നിങ്ങളുടെ ബോട്ടുകൾ സൃഷ്ടിച്ച് നിയന്ത്രിക്കുക, അല്ലെങ്കിൽ ഒന്ന് തുറക്കുക',
};

// Arabic
const Map<String, String> _ar = {
  'What gets included':
      'ما الذي سيتم تضمينه',
  'Nothing could be read from this phone.':
      'تعذّرت قراءة أي شيء من هذا الهاتف.',
  'Close':
      'إغلاق',
  'Please write a short subject.':
      'يُرجى كتابة موضوع قصير.',
  'Please describe the problem in a few words.':
      'يُرجى وصف المشكلة في بضع كلمات.',
  'No email app found':
      'لم يتم العثور على تطبيق بريد إلكتروني',
  'Your report was copied. Paste it into an email to':
      'تم نسخ تقريرك. الصقه في رسالة بريد إلكتروني وأرسلها إلى',
  'OK':
      'حسنًا',
  'Your email app opened. Just press send.':
      'تم فتح تطبيق البريد الإلكتروني. اضغط على إرسال فقط.',
  'Report a problem':
      'الإبلاغ عن مشكلة',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'أخبرنا بما حدث. سيُفتح تطبيق البريد الإلكتروني ومعه رسالتك والتفاصيل التقنية مكتملة — كل ما عليك هو الضغط على إرسال.',
  'App bug':
      'خطأ في التطبيق',
  'Security problem':
      'مشكلة أمنية',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'يُرجى عدم تضمين كلمات المرور أو أرقام PIN أو المفاتيح الخاصة. البريد الإلكتروني غير مشفّر من طرف إلى طرف، لذا صِف المشكلة دون ذكر السرّ نفسه.',
  'Subject':
      'الموضوع',
  'Describe the security problem':
      'صِف المشكلة الأمنية',
  'What happened?':
      'ماذا حدث؟',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      'ماذا يمكن لأحدهم أن يفعل، وكيف؟ خطوات إعادة المشكلة تساعد كثيرًا.',
  'What did you do, what did you expect, and what happened instead?':
      'ماذا فعلت، وماذا كنت تتوقع، وماذا حدث بدلًا من ذلك؟',
  'Include phone and app details':
      'تضمين تفاصيل الهاتف والتطبيق',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'طراز الهاتف وإصدار Android والتطبيق والبطارية والتخزين ونوع الشبكة وما شابه. لا تُضمَّن أبدًا رسائلك أو جهات اتصالك أو رقم هاتفك أو بيانات حسابك أو موقعك أو عنوان IP.',
  'See exactly what is included':
      'عرض ما سيتم تضمينه بالضبط',
  'Include the crash details':
      'تضمين تفاصيل الانهيار',
  'Include recent error details':
      'تضمين تفاصيل الأخطاء الأخيرة',
  'Technical error information from this app, which helps find the cause.':
      'معلومات تقنية عن أخطاء هذا التطبيق تساعد في معرفة السبب.',
  'Send report':
      'إرسال التقرير',
  'Goes to':
      'يُرسل إلى',
  'Protect your IP address?':
      'حماية عنوان IP الخاص بك؟',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'ستمر مكالماتك عبر خادم وسيط حتى لا يتمكن الطرف الآخر من رؤية عنوان IP الخاص بك.\n\nولأن الصوت يسلك طريقًا أطول، قد يزداد التأخير وتقل جودة الصوت وقد يُستهلك مزيد من بيانات الجوال. إذا لم تتصل المكالمة، عُد إلى هنا وأوقف هذا الخيار.',
  'Cancel':
      'إلغاء',
  'Turn on':
      'تشغيل',
  'Calls':
      'المكالمات',
  'Protect IP address in calls':
      'حماية عنوان IP في المكالمات',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'تمرير المكالمات عبر خادم حتى لا يرى الطرف الآخر عنوان IP الخاص بك. هذا يقلل جودة المكالمة.',
  'Not available in this version of the app — it has no relay server set up.':
      'غير متاح في هذا الإصدار من التطبيق — لم يتم إعداد خادم وسيط.',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'مُفعّل — تُمرَّر مكالماتك عبر الخادم الوسيط. إذا لم تتصل المكالمة أو كان الصوت سيئًا، جرّب إيقافه.',
  'App language':
      'لغة التطبيق',
  'Search languages':
      'ابحث عن لغة',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      'اللغات المميّزة بـ"نص التطبيق" مترجمة في أنحاء التطبيق. أما بقية اللغات فتتغير فيها أجزاء النظام (منتقي التاريخ وأزرار الحوار واتجاه الكتابة) ويبقى الباقي بالإنجليزية حاليًا.',
  'Use the same language as your phone':
      'استخدام نفس لغة هاتفك',
  'App text':
      'نص التطبيق',
  'Menus and dialogs':
      'القوائم والحوارات',
  'No language found':
      'لم يتم العثور على لغة',
  'NWisp closed unexpectedly':
      'أُغلق NWisp بشكل غير متوقع',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'يبدو أن NWisp توقف عن العمل في المرة السابقة. هل تريد إرسال تقرير لإصلاحه؟ سيُفتح تطبيق البريد الإلكتروني والتفاصيل مكتملة — كل ما عليك هو الضغط على إرسال.',
  'Not now':
      'ليس الآن',
  'Settings':
      'الإعدادات',
  'Edit Profile':
      'تعديل الملف الشخصي',
  'Log out':
      'تسجيل الخروج',
  'Privacy checkup':
      'فحص الخصوصية',
  'Check your privacy settings and turn them all on in one tap':
      'راجع إعدادات الخصوصية وفعّلها كلها بنقرة واحدة',
  'Account':
      'الحساب',
  'Email, password, account security':
      'البريد الإلكتروني وكلمة المرور وأمان الحساب',
  'Privacy':
      'الخصوصية',
  'Last seen, read receipts, blocked users':
      'آخر ظهور وإيصالات القراءة والمستخدمون المحظورون',
  'Security':
      'الأمان',
  'App lock, biometrics, panic PIN, chat hiding':
      'قفل التطبيق والقياسات الحيوية ورمز الطوارئ وإخفاء الدردشات',
  'Encryption & quantum safety':
      'التشفير والأمان الكمّي',
  'Post-quantum protection, strict mode':
      'حماية ما بعد الكم والوضع الصارم',
  'Private browser':
      'المتصفح الخاص',
  'In-app browser, tracker blocking, search engine':
      'متصفح داخل التطبيق وحظر المتتبعات ومحرك البحث',
  'Login activity':
      'نشاط تسجيل الدخول',
  'Devices and sign-ins on your account':
      'الأجهزة وعمليات تسجيل الدخول على حسابك',
  'Full-screen call alerts':
      'تنبيهات المكالمات بملء الشاشة',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'تسمح للمكالمات الواردة بالرنين فوق شاشة القفل حتى عندما يكون NWisp مغلقًا',
  'Broadcast lists':
      'قوائم البث',
  'Send one message to many people':
      'أرسل رسالة واحدة إلى عدة أشخاص',
  'Chat folders':
      'مجلدات الدردشة',
  'Organise your chats':
      'نظّم دردشاتك',
  'Note to self':
      'ملاحظة لنفسي',
  'A private notepad on this phone':
      'مفكرة خاصة على هذا الهاتف',
  'Scheduled messages':
      'الرسائل المجدولة',
  'Messages waiting to be sent':
      'رسائل بانتظار الإرسال',
  'Starred messages':
      'الرسائل المميّزة بنجمة',
  'Messages you starred':
      'الرسائل التي وضعت عليها نجمة',
  'Media vault':
      'خزنة الوسائط',
  'Locked photos and videos':
      'صور وفيديوهات مقفلة',
  'Protect your IP address in calls':
      'حماية عنوان IP الخاص بك في المكالمات',
  'Notifications':
      'الإشعارات',
  'Muted keywords':
      'الكلمات المفتاحية المكتومة',
  'Chats':
      'الدردشات',
  'Auto-delete, paused chats, home screen layout':
      'الحذف التلقائي والدردشات المتوقفة وتخطيط الشاشة الرئيسية',
  'Appearance':
      'المظهر',
  'Customize how the app looks on this device':
      'خصّص مظهر التطبيق على هذا الجهاز',
  'Report a bug or a security problem':
      'أبلغ عن خطأ أو مشكلة أمنية',
  'Help & About':
      'المساعدة والمعلومات',
  'Help centre, legal, feature guide':
      'مركز المساعدة والقانون ودليل الميزات',
  'Stories':
      'القصص',
  'Announcements':
      'الإعلانات',
  'Community':
      'المجتمع',
  'Phone language':
      'لغة الهاتف',
  'Nearby':
      'بالقرب',
  'Low-data mode':
      'وضع البيانات المنخفضة',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'يستهلك نحو نصف البيانات في المكالمات الصوتية (حوالي 0.12 ميغابايت في الدقيقة). يبدو الصوت أنحف قليلًا. مناسب للاتصالات الضعيفة أو المكلفة.',
  'Recording alerts':
      'تنبيهات التسجيل',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'أبلغ الطرف الآخر إذا بدأ تطبيق آخر على هذا الهاتف بتسجيل الصوت أثناء المكالمة. يصلك تحذير دائمًا عندما يسجّل هاتفه. لا يمكنه اكتشاف تسجيل يتم على جهاز آخر.',
  'Bots':
      'الروبوتات',
  'Create and manage your bots, or open one':
      'أنشئ روبوتاتك وأدرها، أو افتح أحدها',
};

// Spanish
const Map<String, String> _es = {
  'What gets included':
      'Qué se incluye',
  'Nothing could be read from this phone.':
      'No se pudo leer nada de este teléfono.',
  'Close':
      'Cerrar',
  'Please write a short subject.':
      'Escribe un asunto breve.',
  'Please describe the problem in a few words.':
      'Describe el problema en pocas palabras.',
  'No email app found':
      'No se encontró ninguna app de correo',
  'Your report was copied. Paste it into an email to':
      'Tu informe se copió. Pégalo en un correo y envíalo a',
  'OK':
      'Aceptar',
  'Your email app opened. Just press send.':
      'Se abrió tu app de correo. Solo pulsa enviar.',
  'Report a problem':
      'Informar de un problema',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'Cuéntanos qué salió mal. Se abrirá tu app de correo con tu mensaje y los detalles técnicos ya rellenados: solo tienes que pulsar enviar.',
  'App bug':
      'Error de la app',
  'Security problem':
      'Problema de seguridad',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'No incluyas contraseñas, PIN ni claves privadas. El correo no tiene cifrado de extremo a extremo, así que describe el problema sin el secreto en sí.',
  'Subject':
      'Asunto',
  'Describe the security problem':
      'Describe el problema de seguridad',
  'What happened?':
      '¿Qué pasó?',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      '¿Qué podría hacer alguien y cómo? Los pasos para reproducirlo ayudan mucho.',
  'What did you do, what did you expect, and what happened instead?':
      '¿Qué hiciste, qué esperabas y qué ocurrió en su lugar?',
  'Include phone and app details':
      'Incluir detalles del teléfono y de la app',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'Modelo del teléfono, versión de Android y de la app, batería, almacenamiento, tipo de red y similares. Nunca tus mensajes, contactos, número de teléfono, datos de la cuenta, ubicación ni dirección IP.',
  'See exactly what is included':
      'Ver exactamente qué se incluye',
  'Include the crash details':
      'Incluir los detalles del fallo',
  'Include recent error details':
      'Incluir detalles de errores recientes',
  'Technical error information from this app, which helps find the cause.':
      'Información técnica de errores de esta app, que ayuda a encontrar la causa.',
  'Send report':
      'Enviar informe',
  'Goes to':
      'Se envía a',
  'Protect your IP address?':
      '¿Proteger tu dirección IP?',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'Tus llamadas pasarán por un servidor de retransmisión para que la otra persona no vea tu dirección IP.\n\nComo el audio hace un recorrido más largo, las llamadas pueden tener más retraso y menos calidad de sonido, y pueden usar más datos móviles. Si una llamada no se conecta, vuelve aquí y desactiva esta opción.',
  'Cancel':
      'Cancelar',
  'Turn on':
      'Activar',
  'Calls':
      'Llamadas',
  'Protect IP address in calls':
      'Proteger la dirección IP en llamadas',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'Retransmite las llamadas por un servidor para que la otra persona no vea tu dirección IP. Esto reduce la calidad de la llamada.',
  'Not available in this version of the app — it has no relay server set up.':
      'No disponible en esta versión de la app: no tiene servidor de retransmisión configurado.',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'Activado: tus llamadas se retransmiten. Si una llamada no se conecta o suena mal, prueba a desactivarlo.',
  'App language':
      'Idioma de la app',
  'Search languages':
      'Buscar idiomas',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      'Los idiomas marcados con "Texto de la app" están traducidos en toda la app. En los demás cambian las partes del sistema (selectores de fecha, botones de diálogo, dirección del texto) y el resto sigue en inglés por ahora.',
  'Use the same language as your phone':
      'Usar el mismo idioma que tu teléfono',
  'App text':
      'Texto de la app',
  'Menus and dialogs':
      'Menús y diálogos',
  'No language found':
      'No se encontró ningún idioma',
  'NWisp closed unexpectedly':
      'NWisp se cerró inesperadamente',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'Parece que NWisp falló la última vez. ¿Quieres enviar un informe para poder arreglarlo? Se abrirá tu app de correo con los detalles rellenados: solo tienes que pulsar enviar.',
  'Not now':
      'Ahora no',
  'Settings':
      'Ajustes',
  'Edit Profile':
      'Editar perfil',
  'Log out':
      'Cerrar sesión',
  'Privacy checkup':
      'Revisión de privacidad',
  'Check your privacy settings and turn them all on in one tap':
      'Revisa tus ajustes de privacidad y actívalos todos con un toque',
  'Account':
      'Cuenta',
  'Email, password, account security':
      'Correo, contraseña, seguridad de la cuenta',
  'Privacy':
      'Privacidad',
  'Last seen, read receipts, blocked users':
      'Última vez, confirmaciones de lectura, usuarios bloqueados',
  'Security':
      'Seguridad',
  'App lock, biometrics, panic PIN, chat hiding':
      'Bloqueo de la app, biometría, PIN de pánico, ocultar chats',
  'Encryption & quantum safety':
      'Cifrado y seguridad cuántica',
  'Post-quantum protection, strict mode':
      'Protección poscuántica, modo estricto',
  'Private browser':
      'Navegador privado',
  'In-app browser, tracker blocking, search engine':
      'Navegador integrado, bloqueo de rastreadores, buscador',
  'Login activity':
      'Actividad de inicio de sesión',
  'Devices and sign-ins on your account':
      'Dispositivos e inicios de sesión de tu cuenta',
  'Full-screen call alerts':
      'Alertas de llamada a pantalla completa',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'Permite que las llamadas entrantes suenen sobre la pantalla de bloqueo, incluso con NWisp cerrada',
  'Broadcast lists':
      'Listas de difusión',
  'Send one message to many people':
      'Envía un mensaje a muchas personas',
  'Chat folders':
      'Carpetas de chats',
  'Organise your chats':
      'Organiza tus chats',
  'Note to self':
      'Notas personales',
  'A private notepad on this phone':
      'Un bloc de notas privado en este teléfono',
  'Scheduled messages':
      'Mensajes programados',
  'Messages waiting to be sent':
      'Mensajes pendientes de enviar',
  'Starred messages':
      'Mensajes destacados',
  'Messages you starred':
      'Mensajes que marcaste con estrella',
  'Media vault':
      'Bóveda multimedia',
  'Locked photos and videos':
      'Fotos y vídeos bloqueados',
  'Protect your IP address in calls':
      'Proteger tu dirección IP en llamadas',
  'Notifications':
      'Notificaciones',
  'Muted keywords':
      'Palabras clave silenciadas',
  'Chats':
      'Chats',
  'Auto-delete, paused chats, home screen layout':
      'Eliminación automática, chats en pausa, diseño de la pantalla de inicio',
  'Appearance':
      'Apariencia',
  'Customize how the app looks on this device':
      'Personaliza el aspecto de la app en este dispositivo',
  'Report a bug or a security problem':
      'Informa de un error o de un problema de seguridad',
  'Help & About':
      'Ayuda e información',
  'Help centre, legal, feature guide':
      'Centro de ayuda, información legal, guía de funciones',
  'Stories':
      'Historias',
  'Announcements':
      'Anuncios',
  'Community':
      'Comunidad',
  'Phone language':
      'Idioma del teléfono',
  'Nearby':
      'Cerca',
  'Low-data mode':
      'Modo de bajo consumo de datos',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'Usa aproximadamente la mitad de datos en las llamadas de voz (unos 0,12 MB por minuto). Las voces suenan algo más finas. Útil con conexiones débiles o caras.',
  'Recording alerts':
      'Alertas de grabación',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'Avisa a la otra persona si otra app de este teléfono empieza a grabar sonido durante una llamada. A ti siempre se te avisa cuando lo hace su teléfono. No puede detectar una grabación hecha en otro dispositivo.',
  'Bots':
      'Bots',
  'Create and manage your bots, or open one':
      'Crea y gestiona tus bots, o abre uno',
};

// French
const Map<String, String> _fr = {
  'What gets included':
      'Ce qui est inclus',
  'Nothing could be read from this phone.':
      'Impossible de lire quoi que ce soit sur ce téléphone.',
  'Close':
      'Fermer',
  'Please write a short subject.':
      'Veuillez saisir un court objet.',
  'Please describe the problem in a few words.':
      'Veuillez décrire le problème en quelques mots.',
  'No email app found':
      'Aucune application de messagerie trouvée',
  'Your report was copied. Paste it into an email to':
      'Votre rapport a été copié. Collez-le dans un e-mail à l\'adresse',
  'OK':
      'OK',
  'Your email app opened. Just press send.':
      'Votre application de messagerie s\'est ouverte. Appuyez simplement sur Envoyer.',
  'Report a problem':
      'Signaler un problème',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'Dites-nous ce qui n\'a pas fonctionné. Votre application de messagerie s\'ouvrira avec votre message et les détails techniques déjà remplis : il ne vous reste qu\'à appuyer sur Envoyer.',
  'App bug':
      'Bug de l\'application',
  'Security problem':
      'Problème de sécurité',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'N\'incluez pas de mots de passe, de codes PIN ni de clés privées. L\'e-mail n\'est pas chiffré de bout en bout : décrivez donc le problème sans le secret lui-même.',
  'Subject':
      'Objet',
  'Describe the security problem':
      'Décrivez le problème de sécurité',
  'What happened?':
      'Que s\'est-il passé ?',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      'Que pourrait faire quelqu\'un, et comment ? Les étapes pour reproduire le problème aident beaucoup.',
  'What did you do, what did you expect, and what happened instead?':
      'Qu\'avez-vous fait, qu\'attendiez-vous, et que s\'est-il passé à la place ?',
  'Include phone and app details':
      'Inclure les détails du téléphone et de l\'application',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'Modèle du téléphone, versions d\'Android et de l\'application, batterie, stockage, type de réseau, etc. Jamais vos messages, contacts, numéro de téléphone, informations de compte, position ni adresse IP.',
  'See exactly what is included':
      'Voir exactement ce qui est inclus',
  'Include the crash details':
      'Inclure les détails du plantage',
  'Include recent error details':
      'Inclure les détails des erreurs récentes',
  'Technical error information from this app, which helps find the cause.':
      'Informations techniques sur les erreurs de cette application, qui aident à trouver la cause.',
  'Send report':
      'Envoyer le rapport',
  'Goes to':
      'Envoyé à',
  'Protect your IP address?':
      'Protéger votre adresse IP ?',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'Vos appels passeront par un serveur relais afin que l\'autre personne ne puisse pas voir votre adresse IP.\n\nComme l\'audio fait un plus long trajet, les appels peuvent avoir plus de latence et une qualité sonore réduite, et consommer plus de données mobiles. Si un appel ne se connecte pas, revenez ici et désactivez cette option.',
  'Cancel':
      'Annuler',
  'Turn on':
      'Activer',
  'Calls':
      'Appels',
  'Protect IP address in calls':
      'Protéger l\'adresse IP pendant les appels',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'Fait passer les appels par un serveur relais pour que l\'autre personne ne voie pas votre adresse IP. Cela réduit la qualité des appels.',
  'Not available in this version of the app — it has no relay server set up.':
      'Indisponible dans cette version de l\'application : aucun serveur relais n\'est configuré.',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'Activé : vos appels passent par le relais. Si un appel ne se connecte pas ou sonne mal, essayez de désactiver cette option.',
  'App language':
      'Langue de l\'application',
  'Search languages':
      'Rechercher une langue',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      'Les langues marquées « Texte de l\'appli » sont traduites dans toute l\'application. Pour les autres, les éléments système (sélecteurs de date, boutons de dialogue, sens d\'écriture) changent de langue et le reste reste en anglais pour l\'instant.',
  'Use the same language as your phone':
      'Utiliser la même langue que votre téléphone',
  'App text':
      'Texte de l\'appli',
  'Menus and dialogs':
      'Menus et dialogues',
  'No language found':
      'Aucune langue trouvée',
  'NWisp closed unexpectedly':
      'NWisp s\'est fermé de façon inattendue',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'Il semble que NWisp ait planté la dernière fois. Voulez-vous envoyer un rapport pour qu\'il soit corrigé ? Votre application de messagerie s\'ouvrira avec les détails déjà remplis : il ne vous reste qu\'à appuyer sur Envoyer.',
  'Not now':
      'Pas maintenant',
  'Settings':
      'Paramètres',
  'Edit Profile':
      'Modifier le profil',
  'Log out':
      'Se déconnecter',
  'Privacy checkup':
      'Bilan de confidentialité',
  'Check your privacy settings and turn them all on in one tap':
      'Vérifiez vos paramètres de confidentialité et activez-les tous en un geste',
  'Account':
      'Compte',
  'Email, password, account security':
      'E-mail, mot de passe, sécurité du compte',
  'Privacy':
      'Confidentialité',
  'Last seen, read receipts, blocked users':
      'Dernière connexion, accusés de lecture, utilisateurs bloqués',
  'Security':
      'Sécurité',
  'App lock, biometrics, panic PIN, chat hiding':
      'Verrouillage de l\'appli, biométrie, code panique, masquage des discussions',
  'Encryption & quantum safety':
      'Chiffrement et sécurité quantique',
  'Post-quantum protection, strict mode':
      'Protection post-quantique, mode strict',
  'Private browser':
      'Navigateur privé',
  'In-app browser, tracker blocking, search engine':
      'Navigateur intégré, blocage des traceurs, moteur de recherche',
  'Login activity':
      'Activité de connexion',
  'Devices and sign-ins on your account':
      'Appareils et connexions de votre compte',
  'Full-screen call alerts':
      'Alertes d\'appel en plein écran',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'Permet aux appels entrants de sonner sur l\'écran de verrouillage, même quand NWisp est fermé',
  'Broadcast lists':
      'Listes de diffusion',
  'Send one message to many people':
      'Envoyez un message à plusieurs personnes',
  'Chat folders':
      'Dossiers de discussions',
  'Organise your chats':
      'Organisez vos discussions',
  'Note to self':
      'Notes personnelles',
  'A private notepad on this phone':
      'Un bloc-notes privé sur ce téléphone',
  'Scheduled messages':
      'Messages programmés',
  'Messages waiting to be sent':
      'Messages en attente d\'envoi',
  'Starred messages':
      'Messages favoris',
  'Messages you starred':
      'Messages que vous avez marqués d\'une étoile',
  'Media vault':
      'Coffre multimédia',
  'Locked photos and videos':
      'Photos et vidéos verrouillées',
  'Protect your IP address in calls':
      'Protéger votre adresse IP pendant les appels',
  'Notifications':
      'Notifications',
  'Muted keywords':
      'Mots-clés masqués',
  'Chats':
      'Discussions',
  'Auto-delete, paused chats, home screen layout':
      'Suppression automatique, discussions en pause, disposition de l\'écran d\'accueil',
  'Appearance':
      'Apparence',
  'Customize how the app looks on this device':
      'Personnalisez l\'apparence de l\'application sur cet appareil',
  'Report a bug or a security problem':
      'Signaler un bug ou un problème de sécurité',
  'Help & About':
      'Aide et à propos',
  'Help centre, legal, feature guide':
      'Centre d\'aide, mentions légales, guide des fonctionnalités',
  'Stories':
      'Stories',
  'Announcements':
      'Annonces',
  'Community':
      'Communauté',
  'Phone language':
      'Langue du téléphone',
  'Nearby':
      'À proximité',
  'Low-data mode':
      'Mode économie de données',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'Utilise environ moitié moins de données pendant les appels vocaux (environ 0,12 Mo par minute). Les voix sonnent un peu plus fines. Pratique avec une connexion faible ou coûteuse.',
  'Recording alerts':
      'Alertes d\'enregistrement',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'Prévient l\'autre personne si une autre application de ce téléphone commence à enregistrer le son pendant un appel. Vous êtes toujours averti lorsque c\'est son téléphone. Impossible de détecter un enregistrement fait sur un autre appareil.',
  'Bots':
      'Bots',
  'Create and manage your bots, or open one':
      'Créez et gérez vos bots, ou ouvrez-en un',
};

// Portuguese (Brazil)
const Map<String, String> _pt = {
  'What gets included':
      'O que está incluído',
  'Nothing could be read from this phone.':
      'Não foi possível ler nada deste celular.',
  'Close':
      'Fechar',
  'Please write a short subject.':
      'Escreva um assunto curto.',
  'Please describe the problem in a few words.':
      'Descreva o problema em poucas palavras.',
  'No email app found':
      'Nenhum app de e-mail encontrado',
  'Your report was copied. Paste it into an email to':
      'Seu relatório foi copiado. Cole-o em um e-mail e envie para',
  'OK':
      'OK',
  'Your email app opened. Just press send.':
      'Seu app de e-mail foi aberto. Basta tocar em enviar.',
  'Report a problem':
      'Informar um problema',
  'Tell us what went wrong. Your email app will open with your message and the technical details already filled in — you just press send.':
      'Conte o que deu errado. Seu app de e-mail abrirá com sua mensagem e os detalhes técnicos já preenchidos — você só precisa tocar em enviar.',
  'App bug':
      'Bug do app',
  'Security problem':
      'Problema de segurança',
  'Please don\'t include passwords, PINs or private keys. Email is not end-to-end encrypted, so describe the problem without the secret itself.':
      'Não inclua senhas, PINs ou chaves privadas. O e-mail não tem criptografia de ponta a ponta, então descreva o problema sem o segredo em si.',
  'Subject':
      'Assunto',
  'Describe the security problem':
      'Descreva o problema de segurança',
  'What happened?':
      'O que aconteceu?',
  'What could someone do, and how? Steps to reproduce it help a lot.':
      'O que alguém poderia fazer e como? Os passos para reproduzir ajudam muito.',
  'What did you do, what did you expect, and what happened instead?':
      'O que você fez, o que esperava e o que aconteceu em vez disso?',
  'Include phone and app details':
      'Incluir detalhes do celular e do app',
  'Phone model, Android and app version, battery, storage, network type and similar. Never your messages, contacts, phone number, account details, location or IP address.':
      'Modelo do celular, versão do Android e do app, bateria, armazenamento, tipo de rede e itens semelhantes. Nunca suas mensagens, contatos, número de telefone, dados da conta, localização ou endereço IP.',
  'See exactly what is included':
      'Ver exatamente o que é incluído',
  'Include the crash details':
      'Incluir os detalhes da falha',
  'Include recent error details':
      'Incluir detalhes de erros recentes',
  'Technical error information from this app, which helps find the cause.':
      'Informações técnicas de erros deste app, que ajudam a encontrar a causa.',
  'Send report':
      'Enviar relatório',
  'Goes to':
      'Enviado para',
  'Protect your IP address?':
      'Proteger seu endereço IP?',
  'Your calls will go through a relay server so the other person can\'t see your IP address.\n\nBecause the audio takes a longer route, calls may have more delay and lower sound quality, and may use more mobile data. If a call won\'t connect, come back here and turn this off.':
      'Suas chamadas passarão por um servidor de retransmissão para que a outra pessoa não veja seu endereço IP.\n\nComo o áudio faz um caminho mais longo, as chamadas podem ter mais atraso e qualidade de som menor, além de usar mais dados móveis. Se uma chamada não conectar, volte aqui e desative esta opção.',
  'Cancel':
      'Cancelar',
  'Turn on':
      'Ativar',
  'Calls':
      'Chamadas',
  'Protect IP address in calls':
      'Proteger endereço IP nas chamadas',
  'Relay calls through a server so the other person can\'t see your IP address. This reduces call quality.':
      'Retransmite as chamadas por um servidor para que a outra pessoa não veja seu endereço IP. Isso reduz a qualidade da chamada.',
  'Not available in this version of the app — it has no relay server set up.':
      'Indisponível nesta versão do app — ele não tem servidor de retransmissão configurado.',
  'On — your calls are relayed. If a call won\'t connect or sounds poor, try turning this off.':
      'Ativado — suas chamadas são retransmitidas. Se uma chamada não conectar ou soar mal, tente desativar.',
  'App language':
      'Idioma do app',
  'Search languages':
      'Pesquisar idiomas',
  'Languages marked "App text" are translated across the app. For the others, the system parts (date pickers, dialog buttons, text direction) switch language and the rest stays English for now.':
      'Os idiomas marcados com "Texto do app" estão traduzidos em todo o app. Nos demais, as partes do sistema (seletores de data, botões de diálogo, direção do texto) mudam de idioma e o resto continua em inglês por enquanto.',
  'Use the same language as your phone':
      'Usar o mesmo idioma do seu celular',
  'App text':
      'Texto do app',
  'Menus and dialogs':
      'Menus e diálogos',
  'No language found':
      'Nenhum idioma encontrado',
  'NWisp closed unexpectedly':
      'O NWisp fechou inesperadamente',
  'It looks like NWisp crashed last time. Want to send a report so it can be fixed? Your email app opens with the details filled in — you just press send.':
      'Parece que o NWisp travou da última vez. Quer enviar um relatório para que ele seja corrigido? Seu app de e-mail abrirá com os detalhes preenchidos — você só precisa tocar em enviar.',
  'Not now':
      'Agora não',
  'Settings':
      'Configurações',
  'Edit Profile':
      'Editar perfil',
  'Log out':
      'Sair',
  'Privacy checkup':
      'Verificação de privacidade',
  'Check your privacy settings and turn them all on in one tap':
      'Revise suas configurações de privacidade e ative todas com um toque',
  'Account':
      'Conta',
  'Email, password, account security':
      'E-mail, senha, segurança da conta',
  'Privacy':
      'Privacidade',
  'Last seen, read receipts, blocked users':
      'Visto por último, confirmações de leitura, usuários bloqueados',
  'Security':
      'Segurança',
  'App lock, biometrics, panic PIN, chat hiding':
      'Bloqueio do app, biometria, PIN de pânico, ocultar conversas',
  'Encryption & quantum safety':
      'Criptografia e segurança quântica',
  'Post-quantum protection, strict mode':
      'Proteção pós-quântica, modo rigoroso',
  'Private browser':
      'Navegador privado',
  'In-app browser, tracker blocking, search engine':
      'Navegador integrado, bloqueio de rastreadores, mecanismo de busca',
  'Login activity':
      'Atividade de login',
  'Devices and sign-ins on your account':
      'Dispositivos e logins da sua conta',
  'Full-screen call alerts':
      'Alertas de chamada em tela cheia',
  'Lets incoming calls ring over the lock screen, even when NWisp is closed':
      'Permite que as chamadas recebidas toquem sobre a tela de bloqueio, mesmo com o NWisp fechado',
  'Broadcast lists':
      'Listas de transmissão',
  'Send one message to many people':
      'Envie uma mensagem para várias pessoas',
  'Chat folders':
      'Pastas de conversas',
  'Organise your chats':
      'Organize suas conversas',
  'Note to self':
      'Notas pessoais',
  'A private notepad on this phone':
      'Um bloco de notas privado neste celular',
  'Scheduled messages':
      'Mensagens agendadas',
  'Messages waiting to be sent':
      'Mensagens aguardando envio',
  'Starred messages':
      'Mensagens favoritas',
  'Messages you starred':
      'Mensagens que você marcou com estrela',
  'Media vault':
      'Cofre de mídia',
  'Locked photos and videos':
      'Fotos e vídeos bloqueados',
  'Protect your IP address in calls':
      'Proteger seu endereço IP nas chamadas',
  'Notifications':
      'Notificações',
  'Muted keywords':
      'Palavras-chave silenciadas',
  'Chats':
      'Conversas',
  'Auto-delete, paused chats, home screen layout':
      'Exclusão automática, conversas pausadas, layout da tela inicial',
  'Appearance':
      'Aparência',
  'Customize how the app looks on this device':
      'Personalize a aparência do app neste dispositivo',
  'Report a bug or a security problem':
      'Informe um bug ou um problema de segurança',
  'Help & About':
      'Ajuda e sobre',
  'Help centre, legal, feature guide':
      'Central de ajuda, informações legais, guia de recursos',
  'Stories':
      'Stories',
  'Announcements':
      'Anúncios',
  'Community':
      'Comunidade',
  'Phone language':
      'Idioma do celular',
  'Nearby':
      'Por perto',
  'Low-data mode':
      'Modo de economia de dados',
  'Uses about half the data on voice calls (roughly 0.12 MB a minute). Voices sound a little thinner. Good for weak or expensive connections.':
      'Usa cerca de metade dos dados nas chamadas de voz (aproximadamente 0,12 MB por minuto). As vozes soam um pouco mais finas. Bom para conexões fracas ou caras.',
  'Recording alerts':
      'Alertas de gravação',
  'Tell the other person if another app on this phone starts recording sound during a call. You are always warned when theirs does. It can\'t detect a recording made on a different device.':
      'Avisa a outra pessoa se outro app deste celular começar a gravar som durante uma chamada. Você sempre é avisado quando é o celular dela. Não detecta uma gravação feita em outro dispositivo.',
  'Bots':
      'Bots',
  'Create and manage your bots, or open one':
      'Crie e gerencie seus bots, ou abra um',
};
