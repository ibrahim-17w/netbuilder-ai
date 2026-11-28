import 'package:net_builder/services/phrasing_memory_service.dart';

import '../../models/network_intent.dart';
import '../../models/normalized_message.dart';
import '../casual_english.dart';
import 'lexicon.dart';
import '../packet_tracer/brief_reader.dart';
import 'package:flutter/foundation.dart' show compute;

/// THE BRIEF READER: English in, a NetworkIntent out.
///
/// This is the front door of the planner, and it used to be the first 2,400
/// lines of models/network_intent.dart - the data model and the English
/// reader in one file, so neither could be changed without fear of the
/// other. It is separated here.
///
/// WHAT IS IN THIS FILE: reading the words. Normalising them (Arabic digits,
/// spelled-out numbers, dotted masks), bridging the phrasings the lexicon
/// cannot match, finding the sites, and replaying a phrasing the user has
/// already clarified.
///
/// WHAT IS STILL IN network_intent.dart: building the topology out of the
/// normalised brief, in [NetworkIntent.parseBridged]. That is the next
/// extraction, and it is the larger half.
///
/// `NetworkIntent.parseSimple` still exists and still delegates here, so no
/// call site in the app moved when this file was created.

final RegExp _bidiControls = RegExp(r'[‎‏\u202a-\u202e؜]');
final RegExp _arabicDiacritics = RegExp(r'[\u064b-\u065f\u0670\u0640]');
final RegExp _hamzaForms = RegExp(r'[آأإٱ]');
final RegExp _arabicIndicDigits = RegExp(r'[٠-٩۰-۹]');

/// The prefix length of a dotted mask, or null when it is not a mask.
int? _maskToPrefix(String mask) {
  final parts = mask.split('.').map(int.parse).toList();
  if (parts.length != 4) return null;
  var bits = 0;
  var seenZero = false;
  for (final p in parts) {
    if (p > 255) return null;
    for (var b = 7; b >= 0; b--) {
      final one = (p >> b) & 1 == 1;
      if (one && seenZero) return null;
      if (one) {
        bits++;
      } else {
        seenZero = true;
      }
    }
  }
  return bits;
}

/// "10.1.1.0 255.255.255.252", "10.1.1.0 subnet mask 255.255.255.252" and
/// their Arabic spellings become one CIDR, so a single regex serves every
/// brief - including the address tables course briefs are written as.
final RegExp _maskPair = RegExp(
  r'(\d{1,3}(?:\.\d{1,3}){3})[\s,;:]*(?:/|subnet\s+mask|netmask|mask|prefix|qina3|قناع(?:\s+الشبكه)?)?[\s,;:]*(\d{1,3}(?:\.\d{1,3}){3})',
);

/// Arabic phrases -> the English words the rest of this parser already
/// keys on. Keys use folded Arabic; longest-first matching keeps the mode,
/// negation and scope together rather than translating only device nouns.
const List<List<String>> _phraseBridge = [
  // Multi-word names must survive the spelled-out-number bridge: "single" is
  // also the number one, so "single board computer" became "1 1 board
  // computer" and lost its SBC meaning before the lexicon saw it.
  ['single board computer', 'SBC'],
  ['single-board computer', 'SBC'],
  // Controlled Syrian/MSA commands. These carry meaning, not filler.
  ['ولا تغير عناوين الباقي', 'and preserve remaining addresses'],
  ['لا تغير عناوين الباقي', 'preserve remaining addresses'],
  ['خلي عناوين الباقي متل ما هي', 'preserve remaining addresses'],
  ['خلي عدد الاجهزه نفسه', 'preserve device counts'],
  ['خلي عدد الاجهزه متل ما هو', 'preserve device counts'],
  ['خلي عدد الاجهزه كما هو', 'preserve device counts'],
  ['حافظ علي عدد الاجهزه', 'preserve device counts'],
  ['ولا تعدل الشبكه', 'and do not change the network'],
  ['لا تعدل الشبكه', 'do not change the network'],
  ['ولا تغير الشبكه', 'and do not change the network'],
  ['لا تغير الشبكه', 'do not change the network'],
  ['من دون ما تعدل', 'without changing'],
  ['بدون تعديل', 'without changes'],
  ['لا تضيف', 'do not add'],
  ['لا تضف', 'do not add'],
  ['ما تضيف', 'do not add'],
  ['لا تشيل', 'do not remove'],
  ['لا تحذف', 'do not remove'],
  ['لا تستخدم', 'do not use'],
  ['ما تستخدم', 'do not use'],
  ['لا تفعل', 'do not enable'],
  ['لا تعدل', 'do not change'],
  ['لا تغير', 'do not change'],
  ['ولا', 'and do not'],
  ['بدل من', 'instead of'],
  ['بدلا من', 'instead of'],
  ['استبدل', 'replace'],
  ['بدل', 'replace'],
  ['بـ', 'with'],
  ['ب', 'with'],
  ['اشرحلي الفرق بين', 'explain the difference between'],
  ['اشرح لي الفرق بين', 'explain the difference between'],
  ['اشرحلي', 'explain'],
  ['اشرح لي', 'explain'],
  ['اشرح', 'explain'],
  ['شو الفرق بين', 'what is the difference between'],
  ['ما الفرق بين', 'what is the difference between'],
  ['شو بيصير لو', 'what if'],
  ['ماذا لو', 'what if'],
  ['شو رايك', 'what do you recommend'],
  ['بتنصحني', 'would you recommend'],
  ['خلينا نفترض', 'suppose'],
  ['ممكن تضيف', 'can you add'],
  ['فينا نضيف', 'can we add'],
  ['فينا نعملها', 'could we do it'],
  ['ممكن نعملها', 'could we do it'],
  ['بدي', 'create'],
  ['اريد', 'create'],
  ['انشئ', 'create'],
  ['اعمل', 'create'],
  // Dialect verbs. Mapping to the English mode word (want/need/create) tells
  // the parser and the tentative gate what kind of turn this is, instead of
  // leaving a dialect sentence with only its device nouns understood.
  ['ابغى', 'want'],
  ['ابغي', 'want'],
  ['عايز', 'want'],
  ['عاوز', 'want'],
  ['عايزين', 'want'],
  ['عاوزين', 'want'],
  ['بدنا', 'we need'],
  ['محتاج', 'need'],
  ['محتاجه', 'need'],
  ['محتاجين', 'need'],
  ['نحتاج', 'need'],
  ['احتج', 'need'],
  ['سوي', 'create'],
  ['ساوي', 'create'],
  ['اعمللي', 'create'],
  ['اعمل لي', 'create'],
  ['جهز', 'create'],
  ['جهزلي', 'create'],
  ['انشئلي', 'create'],
  ['حط', 'add'],
  ['حطلي', 'add'],
  ['زيد', 'add'],
  ['زود', 'add'],
  ['ضيفلي', 'add'],
  ['اشيل', 'remove'],
  ['شيلها', 'remove'],
  ['امسح', 'remove'],
  ['اغير', 'change'],
  ['ابدل', 'replace'],
  ['ابني', 'build'],
  // Questions, quantities and exclusions. These give the same advice and
  // follow-up modes an English sentence gets; they are not extra device words.
  ['شلون', 'how'],
  ['كيفاش', 'how'],
  ['كيف', 'how'],
  ['ليش', 'why'],
  ['لماذا', 'why'],
  ['وش', 'what'],
  ['ايش', 'what'],
  ['شو', 'what'],
  ['ماذا', 'what'],
  ['وين', 'where'],
  ['فين', 'where'],
  ['قديش', 'how many'],
  ['شقد', 'how many'],
  ['كم', 'how many'],
  ['ما هو', 'what is'],
  ['ما هي', 'what is'],
  ['شو هو', 'what is'],
  ['شو هي', 'what is'],
  ['علي الاقل', 'at least'],
  ['علي الاكثر', 'at most'],
  ['بالضبط', 'exactly'],
  ['تقريبا', 'about'],
  ['حوالي', 'about'],
  ['لكل فرع', 'per branch'],
  ['لكل موقع', 'per site'],
  ['في كل فرع', 'in each branch'],
  ['في كل موقع', 'in each site'],
  ['كل فرع', 'each branch'],
  ['كل موقع', 'each site'],
  ['من غير ما', 'without'],
  ['من غير', 'without'],
  ['ما في', 'without'],
  ['ما بدي dns', 'without dns'],
  ['ما نريد dns', 'without dns'],
  ['ما بدي dhcp', 'without dhcp'],
  ['ما نريد dhcp', 'without dhcp'],
  ['استخدم', 'use'],
  ['ضيف', 'add'],
  ['اضف', 'add'],
  ['شيل', 'remove'],
  ['احذف', 'remove'],
  ['غير اسم', 'rename'],
  ['غير', 'change'],
  ['عدل', 'change'],
  ['صدر الاعدادات', 'export the configurations'],
  ['صدر التهيئه', 'export the configuration'],
  ['ابني الملف', 'build the file'],
  ['بجملتين', 'in two sentences'],
  ['في جملتين', 'in two sentences'],
  ['جملتين', 'two sentences'],
  ['بدون شرح', 'no explanation'],
  ['بلا شرح', 'no explanation'],
  ['فقط الاعدادات', 'configuration only'],
  ['الاعدادات فقط', 'configuration only'],
  ['الاعدادات بس', 'configuration only'],
  ['بالعربي', 'in Arabic'],
  ['بالعربيه', 'in Arabic'],
  ['بالانجليزي', 'in English'],
  ['بالانجليزيه', 'in English'],
  ['باختصار', 'briefly'],
  ['شبكه واحده', 'one network'],
  ['شبكه مسطحه', 'flat network'],
  ['الشبكه', 'network'],
  ['شبكه', 'network'],
  ['فيها', 'with'],
  ['من دون', 'without'],
  ['بلا', 'without'],
  ['فقط', 'only'],
  ['بس', 'only'],
  ['خلي', 'keep'],
  ['حافظ علي', 'preserve'],
  ['متل ما هو', 'as it is'],
  ['متل ما هي', 'as it is'],
  ['كما هو', 'as it is'],
  ['بدون', 'without'],
  ['لازم', 'must'],
  ['يجب', 'must'],
  ['الضيوف', 'guests'],
  ['للموظفين', 'staff'],
  ['الموظفين', 'staff'],
  ['ما يوصلوا', 'must not reach'],
  ['لا يصلوا', 'must not reach'],
  ['اعزل', 'isolate'],
  // --- Arabic vocabulary, second pass -------------------------------------
  // Keys are folded the way this file folds a message: ة is written ه, أ/إ/آ
  // are written ا, ى is written ي. Arabic glues ال onto the noun, so the
  // definite form needs its own key - "الراوتر" can never match the bare
  // "راوتر". Matching is whole-word and longest-first, so a longer phrase
  // below always wins over a noun inside it.
  ['الراوتر اللاسلكي', 'wireless router'],
  ['جهاز التوجيه اللاسلكي', 'wireless router'],
  ['الموجه اللاسلكي', 'wireless router'],
  ['راوتر لاسلكي', 'wireless router'],
  ['راوتر واي فاي', 'wireless router'],
  ['راوتر ويفي', 'wireless router'],
  ['واي فاي راوتر', 'wireless router'],
  ['الراوتر مودم', 'modem'],
  ['راوتر مودم', 'modem'],
  ['مودم راوتر', 'modem'],
  ['السويتش الطبقي', 'layer 3 switch'],
  ['سويتش طبقي', 'layer 3 switch'],
  ['مبدل طبقه ثالثه', 'layer 3 switch'],
  ['سويتش طبقه 3', 'layer 3 switch'],
  ['الاكسس بوينت', 'access point'],
  ['الطابعه الشبكيه', 'network printer'],
  ['طابعه شبكيه', 'network printer'],
  ['الطابعه', 'printer'],
  ['الطابعات', 'printers'],
  ['الكمبيوتر', 'pc'],
  ['الكمبيوترات', 'pcs'],
  ['الحاسوب', 'pc'],
  ['الحواسيب', 'pcs'],
  ['اللابتوب', 'laptop'],
  ['لاب توب', 'laptop'],
  ['اللاب توب', 'laptop'],
  ['الكمبيوتر المحمول', 'laptop'],
  ['الراوترات', 'routers'],
  ['السويتشات', 'switches'],
  ['السيرفر', 'server'],
  ['السيرفرات', 'servers'],
  ['المخدم', 'server'],
  ['مخدم', 'server'],
  ['الجدار الناري', 'firewall'],
  ['جدار الحمايه', 'firewall'],
  ['المودم', 'modem'],
  ['الميراكي', 'meraki'],
  ['ميراكي', 'meraki'],
  ['الكاميرا', 'smart camera'],
  ['كاميرا', 'smart camera'],
  ['كاميرات', 'smart cameras'],
  ['الحساسات', 'sensors'],
  ['حساسات', 'sensors'],
  ['الحساس', 'sensor'],
  ['التلفزيون', 'tv'],
  ['تلفاز', 'tv'],
  ['الموبايل', 'smartphone'],
  ['الهاتف الذكي', 'smartphone'],
  ['هاتف ذكي', 'smartphone'],
  ['التلفون', 'ip phone'],
  ['التابلت', 'tablet'],
  // networks, subnets and addresses
  ['الشبكه المحليه', 'lan'],
  ['شبكه محليه', 'lan'],
  ['الشبكه الواسعه', 'wan'],
  ['شبكه واسعه', 'wan'],
  ['الشبكه الفرعيه', 'subnet'],
  ['شبكه فرعيه', 'subnet'],
  ['عنوان الشبكه', 'network address'],
  ['عناوين الشبكه', 'network addresses'],
  ['عنوان ip', 'ip address'],
  ['البوابه الافتراضيه', 'default gateway'],
  ['العناوين', 'addresses'],
  ['العنوان', 'address'],
  ['المسارات', 'routes'],
  ['المسار', 'route'],
  ['مسار', 'route'],
  ['الايبي', 'ip address'],
  ['ايبي', 'ip address'],
  ['الاي بي', 'ip address'],
  ['اي بي', 'ip address'],
  ['الانترنت', 'internet'],
  ['انترنت', 'internet'],
  ['البروتوكول', 'protocol'],
  ['بروتوكول', 'protocol'],
  ['الفلانات', 'vlans'],
  ['فيلانات', 'vlans'],
  ['فيلان', 'vlan'],
  // links, ports and interfaces
  ['الكونسول', 'console'],
  ['كونسول', 'console'],
  ['الكابل', 'cable'],
  ['كابل', 'cable'],
  ['الوصله', 'link'],
  ['وصله', 'link'],
  ['الرابط', 'link'],
  ['رابط', 'link'],
  ['المنافذ', 'ports'],
  ['المنفذ', 'port'],
  ['البورت', 'port'],
  ['بورت', 'port'],
  ['الواجهه', 'interface'],
  ['واجهه', 'interface'],
  ['الانترفيس', 'interface'],
  ['انترفيس', 'interface'],
  ['الراوتينج', 'routing'],
  ['راوتينج', 'routing'],
  ['التوجيه', 'routing'],
  ['السويتشينج', 'switching'],
  ['سويتشينج', 'switching'],
  ['التبديل', 'switching'],
  ['تبديل', 'switching'],
  // credentials and security
  ['الباسورد', 'password'],
  ['باسورد', 'password'],
  ['باسوورد', 'password'],
  ['اليوزر', 'username'],
  ['يوزر', 'username'],
  ['الصلاحيات', 'permissions'],
  ['مشفر', 'encrypted'],
  ['الشهاده', 'certificate'],
  ['شهاده', 'certificate'],
  ['الفلتره', 'filtering'],
  ['فلتره', 'filtering'],
  ['الحمايه', 'security'],
  ['حمايه', 'security'],
  ['هجوم', 'attack'],
  ['هجمه', 'attack'],
  ['فيروس', 'virus'],
  ['منع الوصول', 'deny access'],
  ['الوصول', 'access'],
  // how people ask, add, change and fix things
  ['خلينا نبني', 'build'],
  ['خلينا نعمل', 'create'],
  ['خلينا نضيف', 'add'],
  ['خلينا نشيل', 'remove'],
  ['خلينا', 'let us'],
  ['فيني', 'can i'],
  ['بتقدر', 'can you'],
  ['تقدر', 'can you'],
  ['ممكن', 'can you'],
  ['يا ريت', 'would like'],
  ['ياريت', 'would like'],
  ['بدك', 'want'],
  ['بدكم', 'want'],
  ['بدها', 'need'],
  ['بدهم', 'need'],
  ['بلزملي', 'need'],
  ['بلزم', 'need'],
  ['بحاجه', 'need'],
  ['لازملي', 'need'],
  ['جيبلي', 'give me'],
  ['جيب', 'give'],
  ['ثبتلي', 'install'],
  ['ثبت', 'install'],
  ['نصب', 'install'],
  ['فعل', 'enable'],
  ['قم بتفعيل', 'enable'],
  ['بتفعيل', 'enable'],
  ['تفعيل', 'enable'],
  ['عطل', 'disable'],
  ['قم بتعطيل', 'disable'],
  ['تعطيل', 'disable'],
  ['الغي', 'remove'],
  ['اصلح', 'fix'],
  ['صلح', 'fix'],
  ['افحص', 'check'],
  ['تفقد', 'check'],
  ['تحقق', 'verify'],
  ['تاكد', 'verify'],
  ['اختبر', 'test'],
  ['جرب', 'test'],
  ['وضح', 'explain'],
  ['فسر', 'explain'],
  ['قارن', 'compare'],
  ['اقترح', 'suggest'],
  ['انصحني', 'recommend'],
  ['نصيحه', 'advice'],
  ['صمملي', 'design'],
  ['صمم', 'design'],
  ['خطط', 'plan'],
  ['احفظ', 'save'],
  ['افتح', 'open'],
  ['استورد', 'import'],
  ['احسبلي', 'calculate'],
  ['احسب', 'calculate'],
  ['انقل', 'move'],
  ['سمي', 'rename'],
  ['ابحث', 'search'],
  ['اعرض', 'show'],
  ['وريني', 'show me'],
  ['فرجيني', 'show me'],
  ['علمني', 'teach me'],
  ['فهمني', 'explain to me'],
  ['ساعدني', 'help me'],
  ['ساعد', 'help'],
  ['اكتبلي', 'write'],
  ['اكتب', 'write'],
  ['حدد', 'set'],
  ['غيرلي', 'change'],
  ['عدللي', 'change'],
  // Present-tense verbs. Arabic attaches the subject to the verb (نشيل = we
  // remove, تضيف = you add, يقارن = it/he compares), so a brief written as a
  // sentence - "لازم نشيل السويتش" - never matched the imperative "شيل". The
  // conjugated form is listed for every verb the table already knows.
  ['نشيل', 'remove'],
  ['تشيل', 'remove'],
  ['يشيل', 'remove'],
  ['نضيف', 'add'],
  ['تضيف', 'add'],
  ['يضيف', 'add'],
  ['اضيف', 'add'],
  ['نغير', 'change'],
  ['تغير', 'change'],
  ['يغير', 'change'],
  ['نبني', 'build'],
  ['تبني', 'build'],
  ['يبني', 'build'],
  ['نعمل', 'create'],
  ['تعمل', 'create'],
  ['نسوي', 'create'],
  ['تسوي', 'create'],
  ['يسوي', 'create'],
  ['نجهز', 'create'],
  ['تجهز', 'create'],
  ['يجهز', 'create'],
  ['نحتاج', 'need'],
  ['تحتاج', 'need'],
  ['يحتاج', 'need'],
  ['نحط', 'add'],
  ['تحط', 'add'],
  ['يحط', 'add'],
  ['نزيد', 'add'],
  ['تزيد', 'add'],
  ['يزيد', 'add'],
  ['نمسح', 'remove'],
  ['تمسح', 'remove'],
  ['يمسح', 'remove'],
  ['نبدل', 'replace'],
  ['تبدل', 'replace'],
  ['يبدل', 'replace'],
  ['نصلح', 'fix'],
  ['تصلح', 'fix'],
  ['يصلح', 'fix'],
  ['نفعل', 'enable'],
  ['تفعل', 'enable'],
  ['يفعل', 'enable'],
  ['نعطل', 'disable'],
  ['تعطل', 'disable'],
  ['يعطل', 'disable'],
  ['نفحص', 'check'],
  ['تفحص', 'check'],
  ['يفحص', 'check'],
  ['نختبر', 'test'],
  ['تختبر', 'test'],
  ['يختبر', 'test'],
  ['نعرض', 'show'],
  ['تعرض', 'show'],
  ['يعرض', 'show'],
  ['نكتب', 'write'],
  ['تكتب', 'write'],
  ['يكتب', 'write'],
  ['نحفظ', 'save'],
  ['تحفظ', 'save'],
  ['يحفظ', 'save'],
  ['نفتح', 'open'],
  ['تفتح', 'open'],
  ['يفتح', 'open'],
  ['نقارن', 'compare'],
  ['تقارن', 'compare'],
  ['يقارن', 'compare'],
  ['اقارن', 'compare'],
  ['نشرح', 'explain'],
  ['تشرح', 'explain'],
  ['يشرح', 'explain'],
  ['نوضح', 'explain'],
  ['توضح', 'explain'],
  ['يوضح', 'explain'],
  ['نصمم', 'design'],
  ['تصمم', 'design'],
  ['يصمم', 'design'],
  ['نخطط', 'plan'],
  ['تخطط', 'plan'],
  ['يخطط', 'plan'],
  ['نحسب', 'calculate'],
  ['نبحث', 'search'],
  ['نلغي', 'remove'],
  ['تلغي', 'remove'],
  ['يلغي', 'remove'],
  ['ننقل', 'move'],
  ['نسمي', 'rename'],
  ['نساعد', 'help'],
  ['تساعد', 'help'],
  ['نختار', 'choose'],
  ['تختار', 'choose'],
  ['يختار', 'choose'],
  ['ما يعمل', 'not working'],
  ['كمان', 'also'],
  ['برضو', 'also'],
  ['برضه', 'also'],
  ['كذلك', 'also'],
  ['ايضا', 'also'],
  ['اضافي', 'additional'],
  ['اضافيه', 'additional'],
  ['زياده', 'additional'],
  ['اكثر من', 'more than'],
  ['اقل من', 'less than'],
  ['بضع', 'a few'],
  ['عدة', 'several'],
  ['كلهم', 'all'],
  ['كلها', 'all'],
  ['جميع', 'all'],
  ['نفس', 'same'],
  ['ضعف', 'double'],
  // questions in the dialects people actually type
  ['ازاي', 'how'],
  ['ازي', 'how'],
  ['علاش', 'why'],
  ['علاه', 'why'],
  ['ليه', 'why'],
  ['متين', 'when'],
  ['ايمتي', 'when'],
  ['امتي', 'when'],
  ['متي', 'when'],
  ['مين', 'who'],
  ['شكون', 'who'],
  ['انهي', 'which'],
  ['انهو', 'which'],
  ['اي واحد', 'which one'],
  ['هل', 'is'],
  ['شو يعني', 'what does mean'],
  ['شو معني', 'what is the meaning of'],
  ['ليش ما', 'why not'],
  ['كيف بقدر', 'how can i'],
  ['كيف اقدر', 'how can i'],
  ['شلون اقدر', 'how can i'],
  ['شو لازم', 'what should'],
  ['شو افضل', 'what is better'],
  ['ايش افضل', 'what is better'],
  ['شو بتنصح', 'what do you recommend'],
  ['تنصحني', 'would you recommend'],
  // symptoms, in the words a user brings to a broken lab
  ['ما عم يشتغل', 'not working'],
  ['ما بيشتغل', 'not working'],
  ['ما يشتغل', 'not working'],
  ['مش شغال', 'not working'],
  ['ما شغال', 'not working'],
  ['مش عامل', 'not working'],
  ['عطلان', 'broken'],
  ['خربان', 'broken'],
  ['النت مقطوع', 'no internet'],
  ['ما في نت', 'no internet'],
  ['ما في انترنت', 'no internet'],
  ['مقطوع', 'down'],
  ['بطيء', 'slow'],
  ['بطيئه', 'slow'],
  ['بطي', 'slow'],
  ['يقطع', 'drops'],
  ['بينقطع', 'drops'],
  ['ما بيوصل', 'cannot reach'],
  ['ما يوصل', 'cannot reach'],
  ['ما بيلاقي', 'cannot find'],
  ['ما يلاقي', 'cannot find'],
  ['ما بيحصل', 'does not get'],
  ['ما بياخد', 'does not get'],
  ['ما بياخد ip', 'does not get an ip'],
  ['تعارض عناوين', 'ip conflict'],
  ['عنوان مكرر', 'duplicate address'],
  ['لمبه حمرا', 'red link'],
  ['اللمبه الحمرا', 'red link'],
  ['ما في اتصال', 'no connection'],
  ['انقطع الاتصال', 'no connection'],
  ['اشاره ضعيفه', 'weak signal'],
  ['واي فاي ضعيف', 'weak signal'],
  // places a lab is laid out across
  ['الطابق الارضي', 'ground floor'],
  ['الطابق الاول', 'first floor'],
  ['الدور الاول', 'first floor'],
  ['الطابق التاني', 'second floor'],
  ['الطابق الثاني', 'second floor'],
  ['المبني', 'building'],
  ['الاستقبال', 'reception'],
  ['المستودع', 'warehouse'],
  ['المختبر', 'lab'],
  ['المعمل', 'lab'],
  ['القاعه', 'hall'],
  ['المدخل', 'entrance'],
  // --- English aliases, same pass -----------------------------------------
  ['home router', 'wireless router'],
  ['broadband router', 'wireless router'],
  ['adsl router', 'wireless router'],
  ['wifi extender', 'access point'],
  ['wi-fi extender', 'access point'],
  ['range extender', 'access point'],
  ['signal booster', 'access point'],
  ['wireless extender', 'access point'],
  ['access switch', 'switch'],
  ['core switch', 'layer 3 switch'],
  ['distribution switch', 'layer 3 switch'],
  ['fire wall', 'firewall'],
  ['sub net', 'subnet'],
  ['ip adress', 'ip address'],
  ['ipaddress', 'ip address'],
  // "computer network" is a network, not one PC more.
  ['computer network', 'network'],
  ['computer networks', 'networks'],
  ['computer lab', 'lab'],
  ['a hundred', '100'],
  ['one hundred', '100'],
  ['two hundred', '200'],
  ['a thousand', '1000'],
  ['one thousand', '1000'],
  ['turn on', 'enable'],
  ['turn off', 'disable'],
  ['switch on', 'enable'],
  ['switch off', 'disable'],
  ['power on', 'enable'],
  ['power off', 'disable'],
  ['get rid of', 'remove'],
  ['take out', 'remove'],
  ['swap out', 'replace'],
  ['swap', 'replace'],
  ['tweak', 'change'],
  ['bump up', 'add'],
  ['beef up', 'add'],
  ['scale up', 'add'],
  // devices and explicit site references
  ['عالفرع التاني', 'at the second branch'],
  ['عالفرع الثاني', 'at the second branch'],
  ['على الفرع التاني', 'at the second branch'],
  ['على الفرع الثاني', 'at the second branch'],
  ['الفرع التاني', 'the second branch'],
  ['الفرع الثاني', 'the second branch'],
  ['عالفرع الاول', 'at the first branch'],
  ['بالفرع التاني', 'at the second branch'],
  ['بالفرع الثاني', 'at the second branch'],
  ['الفرع الاول', 'the first branch'],
  ['الفرع الثالث', 'the third branch'],
  ['اجهزه التوجيه', 'routers'],
  ['جهاز التوجيه', 'router'],
  ['الموجه الرئيسي', 'core router'],
  ['الموجهات', 'routers'],
  ['موجهات', 'routers'],
  ['الموجه', 'router'],
  ['موجه', 'router'],
  ['الراوتر', 'router'],
  ['راوتر', 'router'],
  // Dialect, dual and plural forms. Unvocalised Arabic spells a dual and an
  // oblique plural the same way, so the unambiguous ending decides: loanword
  // duals (-ين) mean two, MSA sound plurals stay plural.
  ['راوترين', '2 routers'],
  ['راوتران', '2 routers'],
  ['سويتشين', '2 switches'],
  ['سويتشان', '2 switches'],
  ['سيرفرين', '2 servers'],
  ['سيرفران', '2 servers'],
  ['كمبيوترين', '2 pcs'],
  ['كمبيوتران', '2 pcs'],
  ['حاسوبين', '2 pcs'],
  ['حاسوبان', '2 pcs'],
  ['جهازين', '2 pcs'],
  ['جهازان', '2 pcs'],
  ['طابعتين', '2 printers'],
  ['طابعتان', '2 printers'],
  ['فايروولين', '2 firewalls'],
  ['فايروولان', '2 firewalls'],
  ['موجهان', '2 routers'],
  ['مبدلان', '2 switches'],
  ['خادمان', '2 servers'],
  ['موجهين', 'routers'],
  ['مبدلين', 'switches'],
  ['خادمين', 'servers'],
  ['راوترات', 'routers'],
  ['راوترز', 'routers'],
  ['سويتشات', 'switches'],
  ['سويتشز', 'switches'],
  ['سيرفرات', 'servers'],
  ['كمبيوترات', 'pcs'],
  ['حاسوبات', 'pcs'],
  ['لابتوبات', 'laptops'],
  ['تابلتات', 'tablets'],
  ['طابعات', 'printers'],
  ['فايروول', 'firewall'],
  ['فايروولات', 'firewalls'],
  ['جدران ناريه', 'firewalls'],
  ['نقاط وصول', 'access points'],
  ['اكسس بوينتس', 'access points'],
  ['مودمات', 'modems'],
  ['شبكتين', '2 networks'],
  ['شبكات', 'networks'],
  ['فرعين', '2 branches'],
  ['فروع', 'branches'],
  ['موقعين', '2 sites'],
  ['مواقع', 'sites'],
  ['طابقان', '2 floors'],
  ['طابقين', 'floors'],
  ['طوابق', 'floors'],
  ['مكتبان', '2 offices'],
  ['مكتبين', 'offices'],
  ['مكاتب', 'offices'],
  ['مبنيان', '2 buildings'],
  ['مبنيين', 'buildings'],
  ['مباني', 'buildings'],
  ['المبدلات', 'switches'],
  ['مبدلات', 'switches'],
  ['المبدله', 'switch'],
  ['مبدله', 'switch'],
  ['المبدل', 'switch'],
  ['مبدل', 'switch'],
  ['السويتش', 'switch'],
  ['سويتش', 'switch'],
  ['الخوادم', 'servers'],
  ['خوادم', 'servers'],
  ['الخادم', 'server'],
  ['خادم', 'server'],
  ['سيرفر', 'server'],
  ['اجهزه الموظفين', 'pcs'],
  ['الاجهزه', 'pcs'],
  ['اجهزه', 'pcs'],
  ['جهاز', 'pc'],
  ['حاسوب محمول', 'laptop'],
  ['لابتوب', 'laptop'],
  ['حاسوب', 'pc'],
  ['كمبيوتر', 'pc'],
  ['جدار ناري', 'firewall'],
  ['الفايروول', 'firewall'],
  ['نقطه وصول', 'access point'],
  ['اكسس بوينت', 'access point'],
  ['هاتف ip', 'ip phone'],
  ['هاتف', 'ip phone'],
  ['طابعه', 'printer'],
  ['سحابه', 'cloud'],
  ['مودم', 'modem'],
  ['واي فاي', 'wireless'],
  ['لاسلكي', 'wireless'],
  ['تابلت', 'tablet'],
  ['جوال', 'smartphone'],
  // security, services and the words that decide the security profile
  ['خادم aaa', 'aaa server'],
  ['خادم dhcp', 'dhcp server'],
  ['خادم الويب', 'web server'],
  ['خادم ويب', 'web server'],
  ['خادم dns', 'dns server'],
  ['خادم البريد', 'mail server'],
  ['خادم ftp', 'ftp server'],
  ['امن المنافذ', 'port security'],
  ['تامين المنافذ', 'port security'],
  ['امن الشبكه', 'network security'],
  ['امن الشبكات', 'network security'],
  ['حمايه الشبكه', 'network security'],
  ['التنصت علي dhcp', 'dhcp snooping'],
  ['تنصت dhcp', 'dhcp snooping'],
  ['خوادم وهميه', 'rogue dhcp servers'],
  ['خادم وهمي', 'rogue dhcp server'],
  ['منفذ موثوق', 'trusted port'],
  ['منافذ المستخدمين', 'user ports'],
  ['قائمه التحكم بالوصول', 'access list'],
  ['التحكم بالوصول', 'access control'],
  ['تحكم بالوصول', 'access control'],
  ['المصادقه المركزيه', 'centralized authentication'],
  ['مصادقه مركزيه', 'centralized authentication'],
  ['مصادقه', 'authentication'],
  ['تاكاكس', 'tacacs'],
  ['نفق ipsec', 'ipsec vpn'],
  ['نفق', 'vpn tunnel'],
  ['موقع الي موقع', 'site-to-site'],
  ['بين الفرعين', 'site-to-site'],
  ['مفتاح مشترك', 'pre-shared key'],
  ['مفتاح اولي', 'pre-shared key'],
  ['اسم المستخدم', 'username'],
  ['كلمه المرور', 'password'],
  ['كلمه السر', 'password'],
  ['كلمه مرور', 'password'],
  ['تشفير', 'encryption'],
  ['اوقات الدوام', 'office hours'],
  ['وقت الدوام', 'office hours'],
  ['ساعات العمل', 'office hours'],
  ['الدوام الرسمي', 'office hours'],
  ['الفرع الرئيسي', 'headquarters'],
  ['الفرع الفرعي', 'branch'],
  ['فرع رئيسي', 'headquarters'],
  ['فرع فرعي', 'branch'],
  ['الشبكه العامه', 'wan'],
  ['شبكه عامه', 'wan'],
  ['وصله تسلسليه', 'serial link'],
  ['تسلسليه', 'serial'],
  ['تسلسلي', 'serial'],
  ['قناع الشبكه', 'subnet mask'],
  ['العنونه', 'addressing'],
  ['بوابه افتراضيه', 'default gateway'],
  ['بوابه', 'gateway'],
  ['توجيه ديناميكي', 'dynamic routing'],
  ['توجيه ثابت', 'static route'],
  ['اوسبف', 'ospf'],
  // English spellings the parser should accept as the same request
  ['business hours', 'office hours'],
  ['working hours', 'office hours'],
  ['work hours', 'office hours'],
  ['site to site', 'site-to-site'],
  ['site2site', 'site-to-site'],
  ['centralised authentication', 'centralized authentication'],
  // Plain-English wordings that used to fall through the parser.
  ['half a dozen', '6'],
  ['half dozen', '6'],
  ['a pair of', '2'],
  ['a couple of', '2'],
  ['point-to-point', 'serial link'],
  ['point to point', 'serial link'],
  // "guest" is kept in the bridge: the parser only needs the wireless
  // keyword, while the sizing pack and the VLAN wording need to know the
  // network is for guests (guest wifi → guest wireless).
  ['guest wi-fi', 'guest wireless'],
  ['guest wifi', 'guest wireless'],
  ['guest wlan', 'guest wireless'],
  ['wi-fi router', 'wireless router'],
  ['wifi router', 'wireless router'],
  ['l3 switch', 'layer 3 switch'],
  ['l2 switch', 'switch'],
  ['trunk between the switches', 'switch trunk'],
  ['trunk between switches', 'switch trunk'],
  ['tacacs+', 'tacacs'],
  // How people actually open a request. These are stripped rather than
  // translated: what follows them is the lab, and the parser only ever read
  // the numbers and device words.
  ['can you make me', ''],
  ['can you make', ''],
  ['can you create', ''],
  ['can you build me', ''],
  ['can you build', ''],
  ['could you make', ''],
  ['could you build', ''],
  ['please make', ''],
  ['please build', ''],
  ['please create', ''],
  ['please set up', ''],
  ['i want to make', ''],
  ['i want to build', ''],
  ['i want to create', ''],
  ['i want a', ''],
  ['i want', ''],
  ['i need to make', ''],
  ['i need to build', ''],
  ['i am looking to build', ''],
  ['i am looking to', ''],
  ['we are looking to', ''],
  ['looking to build', ''],
  ['i would like to make', ''],
  ['i would like a', ''],
  ['i would like', ''],
  ['we would like', ''],
  ['i could use', ''],
  ['we could use', ''],
  ['spin up a', ''],
  ['spin up', ''],
  ['stand up a', ''],
  ['stand up', ''],
  ['throw together a', ''],
  ['throw together', ''],
  ['put together a', ''],
  ['put together', ''],
  ['whip up a', ''],
  ['whip up', ''],
  ['hook me up with', ''],
  ['hook up', ''],
  ['i need a', ''],
  ['i need', ''],
  ['i.d like to build', ''],
  ['i.d like a', ''],
  ['i would like to build', ''],
  ['we need a', ''],
  ['we need', ''],
  ['give me a', ''],
  ['give me', ''],
  ['set me up', ''],
  ['set up a', ''],
  ['help me build', ''],
  ['help me set up', ''],
  ['make me a', ''],
  ['build me a', ''],
  ['create a', ''],
  ['design a', ''],
  ['plan a', ''],
  ['plan me a', ''],
  ['draw up a', ''],
  ['i have a', ''],
  ['we have a', ''],
  ['there is a', ''],
  ['there.s a', ''],
  ['my lab', ''],
  ['my network', ''],
  ['the lab', ''],
];

/// Numbers a brief may spell out instead of typing - English and Arabic.
bool _isAscii(String s) => s.codeUnits.every((c) => c < 128);

/// Spelled Arabic compounds: "خمسة وعشرين جهازاً" is 25 devices, not 5 and
/// 20. Unvocalised Arabic folds to one spelling per word, and the conjunction
/// pass below splits the و, so the sum has to be computed first - on the
/// folded text, which is why every key is written the folded way (ة as ه).
const Map<String, int> _arabicOnes = {
  'واحد': 1,
  'احدي': 1,
  'احد': 1,
  'اثنين': 2,
  'اثنان': 2,
  'اثني': 2,
  'اثنا': 2,
  'ثلاثه': 3,
  'اربع': 4,
  'خمس': 5,
  'خمسه': 5,
  'ست': 6,
  'سته': 6,
  'سبع': 7,
  'سبعه': 7,
  'ثمان': 8,
  'ثماني': 8,
  'ثمانيه': 8,
  'تسع': 9,
  'تسعه': 9,
};

const Map<String, int> _arabicTens = {
  'عشرين': 20,
  'ثلاثين': 30,
  'اربعين': 40,
  'خمسين': 50,
  'ستين': 60,
  'سبعين': 70,
  'ثمانين': 80,
  'تسعين': 90,
  'عشر': 10,
  'عشره': 10,
};

final RegExp _arabicCompoundNumber = RegExp(
  '(?<![A-Za-z0-9_\\u0621-\\u064a])'
  '(${_arabicOnes.keys.map(RegExp.escape).join('|')})\\s+و?\\s*'
  '(${_arabicTens.keys.map(RegExp.escape).join('|')})'
  '(?![A-Za-z0-9_\\u0621-\\u064a])',
);

// Split only the conjunction attached to a known word, digit or technical
// token, not every Arabic word beginning with waw and never a literal value.
final Set<String> _arabicConjunctionWords = {
  for (final phrase in _phraseBridge)
    if (!_isAscii(phrase[0])) phrase[0].split(' ').first,
  for (final word in numberWords.keys)
    if (!_isAscii(word)) word,
};
final RegExp _arabicConjunction = RegExp(
  '(?<![A-Za-z0-9_\\u0621-\\u064a])و(?='
  '(?:${_arabicConjunctionWords.map(RegExp.escape).join('|')})(?![\\u0621-\\u064a])|'
  r'[0-9]|(?:OSPF|EIGRP|DNS|DHCP|PCs?|VLANs?)\b|\s)',
  caseSensitive: false,
);

/// True when the brief ties this subnet to a site: "192.168.20.0/24 at the
/// branch", "... for HQ".
///
/// Deliberately narrow: the site word has to follow the subnet within a
/// couple of words and sit in the same clause, so a subnet mentioned inside
/// a sentence about something else ("the 10.0.0.0/30 transit link between
/// the sites") is never claimed by a site it did not name.
final RegExp _siteCue = RegExp(
  r'^\s*(?:is\s+)?(?:at|for|in|on|to)\s+(?:the\s+|our\s+|its\s+)?'
  r'(?:headquarters|hq|main|site|branch|office|building|floor|school|'
  r'campus|department|location|store|shop)\b',
);

bool subnetSitsAtASite(String text, String cidr) {
  final at = text.indexOf(cidr);
  if (at < 0) return false;
  final from = at + cidr.length;
  final tail = text
      .substring(from, from + 40 > text.length ? text.length : from + 40)
      .toLowerCase();
  return _siteCue.hasMatch(tail);
}

/// How many identical sites a brief describes - "2 branch offices",
/// "three floors", "2 sites" - or null when it describes one.  The digits
/// must sit directly on the site word ("2 offices", not "2 routers in the
/// office"), and a count of one is not an expansion.
final RegExp _siteCountPhrase = RegExp(
  r'(\d{1,3})\s*(?:separate\s+|identical\s+|different\s+|remote\s+|branch\s+|physical\s+)?'
  r'(?:offices?|branches|sites?|floors?|buildings?|classrooms?|departments?|locations?)\b',
  caseSensitive: false,
);

int? siteCount(String text) {
  final m = _siteCountPhrase.firstMatch(text);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return (n < 2 || n > 25) ? null : n;
}

final RegExp _perSiteCue = RegExp(
  r'\b(?:each|per\s+(?:site|office|branch|floor|building|location|classroom|department))\b',
  caseSensitive: false,
);

final RegExp _perSiteAside = RegExp(
  r'[,;]?\s*(?:plus|as well as|in addition|additionally|also|and an additional)\b',
  caseSensitive: false,
);

final RegExp _sentenceBreak = RegExp(r'[.;\n]');

const List<String> _perSiteWords = [
  'router',
  'gateway',
  'switch',
  'pc',
  'workstation',
  'desktop',
  'server',
];

final Set<String> _perSiteKeywords = {
  ..._perSiteWords,
  for (final kind in deviceKinds) ...kind.keywords,
};

final Map<String, RegExp> _countPatternByWord = {
  // One role adjective may sit between the count and the noun - enterprise
  // briefs say "2 core routers", not just "2 routers".
  for (final w in _perSiteKeywords)
    w: RegExp(
      '(\\d{1,3})\\s*(?:(?:core|edge|distribution|backbone|wan|hq|branch|'
      'main|central)\\s+)?${RegExp.escape(w)}s?\\b',
    ),
};

final Map<String, RegExp> _barePatternByWord = {
  for (final w in _perSiteKeywords) w: RegExp('\\b${RegExp.escape(w)}\\b'),
};

/// The device counts that belong to ONE site of a brief worded as
/// "... each with a router, a switch and 3 pcs".
///
/// The clause runs from the cue to the end of the sentence or to a
/// 'plus/also' aside, so "plus one server at headquarters" keeps its own
/// global count instead of being multiplied with everything else.
/// Returns null when the brief has no per-site cue at all.
Map<String, int>? perSiteCounts(String text) {
  final cue = _perSiteCue.firstMatch(text);
  if (cue == null) return null;
  var clause = text.substring(cue.end);
  final aside = _perSiteAside.firstMatch(clause);
  if (aside != null) clause = clause.substring(0, aside.start);
  final stop = clause.indexOf(_sentenceBreak);
  if (stop >= 0) clause = clause.substring(0, stop);
  final lower = clause.toLowerCase();
  // The count often comes BEFORE the cue: "a server in each site", "3 pcs
  // per site". Read the run-up to the cue as well (same sentence, and never
  // the site count itself), so both word orders mean the same thing.
  final lead = text.substring(0, cue.start);
  var runUp = lead.substring(lead.lastIndexOf(RegExp(r'[.;\n]')) + 1);
  if (runUp.length > 80) runUp = runUp.substring(runUp.length - 80);
  final runUpLower = runUp.toLowerCase();
  // Only a count the cue actually governs belongs to every site: "a server in
  // each site" and "3 pcs per site" do, while the totals in "two sites with 4
  // switches, each site has 2 pcs" are stated before a cue they are not part
  // of.
  final perCue = cue.group(0)!.toLowerCase().startsWith('per');
  final introduced = RegExp(
    r'\b(?:in|for|with|at|inside|within|to)\s+(?:the\s+|every\s+|its\s+)?$',
  ).hasMatch(runUpLower);
  final before = perCue || introduced ? runUpLower : '';

  int countIn(List<String> words, String text) {
    for (final w in words) {
      final pattern = _countPatternByWord[w]!;
      for (final m in pattern.allMatches(text)) {
        // "VLAN 20 servers" names the VLAN - the 20 is an ID, not a count.
        // Taking it inflated every later lab: "4 switches with VLAN 20
        // servers" built twenty servers where the brief named none.
        if (RegExp(r'vlan\s*$').hasMatch(text.substring(0, m.start))) {
          continue;
        }
        return int.parse(m.group(1)!);
      }
    }
    for (final w in words) {
      if (_barePatternByWord[w]!.hasMatch(text)) return 1;
    }
    return 0;
  }

  /// "3 pcs" and a bare "a switch" both mean something per site; the clause
  /// after the cue is read first, then the run-up that introduces it.
  int countOf(List<String> words) {
    final after = countIn(words, lower);
    return after > 0 ? after : countIn(words, before);
  }

  final counts = <String, int>{
    'router': countOf(['router', 'gateway']),
  };
  counts['switch'] = countOf(['switch']);
  counts['pc'] = countOf(['pc', 'workstation', 'desktop', 'hosts']);
  counts['server'] = countOf(['server', 'nas', 'network attached storage']);
  for (final kind in deviceKinds) {
    if (const ['router', 'switch', 'pc', 'server'].contains(kind.type)) {
      continue;
    }
    counts[kind.type] = countOf(kind.keywords);
  }
  return counts;
}

final RegExp _extraSpaces = RegExp(r'[ \t]+');

/// The phrase bridge, longest key first, with the pattern each ASCII key is
/// matched by already compiled.
///
/// Whole words only. These keys are matched case-insensitively without
/// boundaries, so a filler phrase for the standalone article "a" -
/// 'set up a' - also matched the first eight characters of any word
/// starting with a: "set up AAA" became "AA", and the AAA role word
/// vanished from the brief before the roles were read. A key that
/// starts and ends on a word character must not match inside one.
final List<({RegExp? pattern, String from, String to})> _phraseBridgeTable = [
  for (final e in [
    ..._phraseBridge,
  ]..sort((a, b) => b[0].length.compareTo(a[0].length)))
    if (_isAscii(e[0]))
      (
        pattern: RegExp(
          '${RegExp.escape(e[0][0]) == e[0][0] ? r'\b' : ''}'
          '${RegExp.escape(e[0])}'
          '${RegExp.escape(e[0][e[0].length - 1]) == e[0][e[0].length - 1] ? r'\b' : ''}',
          caseSensitive: false,
        ),
        from: e[0],
        to: e[1],
      )
    else
      (
        pattern: RegExp(
          '(?<![A-Za-z0-9_\\u0621-\\u064a])${RegExp.escape(e[0])}'
          '(?![A-Za-z0-9_\\u0621-\\u064a])',
          caseSensitive: false,
        ),
        from: e[0],
        to: e[1],
      ),
];

/// The legacy parser and the request adapter share one literal-safe bridge.
String bridgeBrief(String raw) => bridgeBriefWithMapping(raw).normalizedText;

/// The same bridge pass as [bridgeBrief], retaining UTF-16 source offsets.
/// Kept beside the legacy bridge so both readers use the same phrase table,
/// masks, digit rules and number vocabulary.
NormalizedMessage bridgeBriefWithMapping(String raw) {
  final tracked = _TrackedText(raw);
  tracked.replaceAll(_bidiControls, (_) => ' ');
  tracked.replaceAll(_arabicDiacritics, (_) => '');
  tracked.replaceAll(_hamzaForms, (_) => 'ا');
  tracked.replaceAll(RegExp('ى'), (_) => 'ي');
  tracked.replaceAll(RegExp('ة'), (_) => 'ه');
  tracked.replaceAll(RegExp('،'), (_) => ',');
  tracked.replaceAll(RegExp('؛'), (_) => ';');
  tracked.replaceAll(RegExp('؟'), (_) => '?');
  tracked.replaceAll(_arabicIndicDigits, (match) {
    final code = match.group(0)!.codeUnitAt(0);
    return '${code >= 0x06f0 ? code - 0x06f0 : code - 0x0660}';
  });
  tracked.replaceAll(_maskPair, (match) {
    final prefix = _maskToPrefix(match.group(2)!);
    if (prefix == null || prefix == 0) return match.group(0)!;
    return '${match.group(1)!}/$prefix';
  }, allowAddressPair: true);
  tracked.replaceAll(_arabicCompoundNumber, (match) {
    final value =
        (_arabicOnes[match.group(1)!] ?? 0) +
        (_arabicTens[match.group(2)!] ?? 0);
    return '$value';
  });
  tracked.replaceAll(_arabicConjunction, (_) => 'and ');
  tracked.replaceAll(
    RegExp(
      r'(?<![A-Za-z0-9_\u0621-\u064a])ب(?=(?:OSPF|EIGRP|BGP|static)\b)',
      caseSensitive: false,
    ),
    (_) => 'with ',
  );
  for (final entry in _phraseBridgeTable) {
    // Opening/request words carry mode. Keep them: deleting "i need" or
    // "my network" makes exploration and do-not-change clauses unreadable.
    if (entry.to.isEmpty) continue;
    final pattern = entry.pattern;
    if (pattern != null) {
      tracked.replaceAll(pattern, (_) => entry.to);
    } else if (tracked.text.contains(entry.from)) {
      tracked.replaceAll(RegExp(RegExp.escape(entry.from)), (_) => entry.to);
    }
  }
  tracked.replaceAll(
    RegExp(r"(?<![A-Za-z0-9_])[A-Za-z]+(?:['’][A-Za-z]+)?(?![A-Za-z0-9_])"),
    (match) => CasualEnglish.normalizeToken(match.group(0)!),
  );
  // Numbers retain punctuation/newlines and offsets; converting a whole
  // space-delimited token used to swallow the comma after a spelled number.
  tracked.replaceAll(
    RegExp(
      r'(?<![A-Za-z0-9_\u0621-\u064a])[A-Za-z\u0621-\u064a]+(?![A-Za-z0-9_\u0621-\u064a])',
    ),
    (match) =>
        numberWords[match.group(0)!.toLowerCase()]?.toString() ??
        match.group(0)!,
  );
  tracked.replaceAll(_extraSpaces, (_) => ' ');
  return tracked.finish();
}

/// Applies whole-string bridge edits while keeping the source range of each
/// UTF-16 code unit. A phrase replacement maps to its complete original
/// phrase; removed text is retained as a zero-width deletion segment.
class _TrackedText {
  final String _original;
  final List<(int, int)> _protected;
  final List<(int, int)> _opaque;
  String text;
  List<int> _starts;
  List<int> _ends;
  List<({int at, int start, int end})> _deletions = [];

  _TrackedText(this.text)
    : _original = text,
      _protected = _literalRanges(text),
      _opaque = _opaqueValueRanges(text),
      _starts = [for (var i = 0; i < text.length; i++) i],
      _ends = [for (var i = 0; i < text.length; i++) i + 1];

  void replaceAll(
    RegExp pattern,
    String Function(RegExpMatch) replacement, {
    bool allowAddressPair = false,
  }) {
    final matches = pattern.allMatches(text).toList(growable: false);
    if (matches.isEmpty) return;
    final oldText = text;
    final oldStarts = _starts;
    final oldEnds = _ends;
    final oldDeletions = _deletions;
    final buffer = StringBuffer();
    final starts = <int>[];
    final ends = <int>[];
    final deletions = <({int at, int start, int end})>[];
    final skipped = <RegExpMatch>{};
    var cursor = 0;
    var outputLength = 0;

    void copyRange(int from, int to) {
      if (from >= to) return;
      buffer.write(oldText.substring(from, to));
      starts.addAll(oldStarts.getRange(from, to));
      ends.addAll(oldEnds.getRange(from, to));
      outputLength += to - from;
    }

    for (final match in matches) {
      copyRange(cursor, match.start);
      if (_isProtected(
        match.start,
        match.end,
        allowAddressPair: allowAddressPair,
      )) {
        skipped.add(match);
        copyRange(match.start, match.end);
        cursor = match.end;
        continue;
      }
      final outputStart = outputLength;
      var sourceStart = _original.length;
      var sourceEnd = 0;
      for (var i = match.start; i < match.end; i++) {
        if (oldStarts[i] < sourceStart) sourceStart = oldStarts[i];
        if (oldEnds[i] > sourceEnd) sourceEnd = oldEnds[i];
      }
      for (final removed in oldDeletions) {
        if (removed.at < match.start || removed.at > match.end) continue;
        if (removed.start < sourceStart) sourceStart = removed.start;
        if (removed.end > sourceEnd) sourceEnd = removed.end;
      }
      final value = replacement(match);
      // A no-op must keep each code unit's original coordinates. Mapping an
      // unchanged token to a single range loses exact named-device evidence.
      if (value == match.group(0)) {
        skipped.add(match);
        copyRange(match.start, match.end);
        cursor = match.end;
        continue;
      }
      buffer.write(value);
      if (value.isNotEmpty) {
        if (sourceStart == _original.length && sourceEnd == 0) {
          sourceStart = match.start;
          sourceEnd = match.end;
        }
        for (var i = 0; i < value.length; i++) {
          starts.add(sourceStart);
          ends.add(sourceEnd);
        }
      } else if (sourceEnd > sourceStart) {
        deletions.add((at: outputStart, start: sourceStart, end: sourceEnd));
      }
      outputLength += value.length;
      cursor = match.end;
    }
    copyRange(cursor, oldText.length);

    int moveBoundary(int boundary) {
      var delta = 0;
      for (final match in matches) {
        if (skipped.contains(match)) continue;
        if (boundary < match.start) break;
        final nextValue = replacement(match);
        if (boundary <= match.end) {
          return match.start + delta + nextValue.length;
        }
        delta += nextValue.length - (match.end - match.start);
      }
      return boundary + delta;
    }

    for (final removed in oldDeletions) {
      if (matches.any(
        (m) =>
            !skipped.contains(m) &&
            removed.at >= m.start &&
            removed.at <= m.end,
      )) {
        continue;
      }
      deletions.add((
        at: moveBoundary(removed.at),
        start: removed.start,
        end: removed.end,
      ));
    }
    text = buffer.toString();
    _starts = starts;
    _ends = ends;
    _deletions = deletions;
  }

  bool _isProtected(int start, int end, {bool allowAddressPair = false}) {
    var sourceStart = _original.length;
    var sourceEnd = 0;
    for (var i = start; i < end; i++) {
      if (_starts[i] < sourceStart) sourceStart = _starts[i];
      if (_ends[i] > sourceEnd) sourceEnd = _ends[i];
    }
    return _protected.any((range) {
      if (range.$1 >= sourceEnd || range.$2 <= sourceStart) return false;
      // Address+mask -> CIDR is an existing, semantic address-reader rule,
      // not a fuzzy literal rewrite. Permit only two complete bare IPv4
      // literals, never an address inside a quoted value/path/SSID/secret.
      if (allowAddressPair &&
          range.$1 >= sourceStart &&
          range.$2 <= sourceEnd &&
          RegExp(
            r'^\d{1,3}(?:\.\d{1,3}){3}$',
          ).hasMatch(_original.substring(range.$1, range.$2)) &&
          !_opaque.any(
            (opaque) => opaque.$1 < range.$2 && opaque.$2 > range.$1,
          )) {
        return false;
      }
      return true;
    });
  }

  static List<(int, int)> _literalRanges(String text) {
    final ranges = <(int, int)>[];
    final patterns = <RegExp>[
      RegExp(r'`[^`\n]*`|"[^"\n]*"|(?<!\w)\x27[^\x27\n]*\x27'),
      RegExp(r'(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/]|\\\\|/)[^\s,;]+'),
      RegExp(r'\b[A-Za-z_][A-Za-z0-9_.-]*\.[A-Za-z][A-Za-z0-9_.-]*\b'),
      RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,3})?\b'),
      RegExp(r'\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', caseSensitive: false),
      RegExp(
        r'(?<![A-Za-z0-9])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:/\d{1,3})?(?![A-Za-z0-9])',
        caseSensitive: false,
      ),
      RegExp(r'\b[A-Za-z][A-Za-z0-9_.-]*\d[A-Za-z0-9_.-]*\b'),
      // Case-sensitive names and explicitly named values stay byte-for-byte.
      RegExp(r'\b[A-Za-z]*[a-z][A-Z][A-Za-z]*\b'),
      RegExp(
        r'\b(?:FastEthernet|GigabitEthernet|TenGigabitEthernet|TwentyFiveGigE|HundredGigE|Ethernet|Serial|Async|Fa|Gi|Te|Eth|Se|F|G|S|Vlan|Console|Aux(?:iliary)?|USB|Coax(?:ial)?|Port)\s*\d+(?:/\d+){0,3}\b',
        caseSensitive: false,
      ),
      RegExp(r'\b(?:GPIO|D|A)\d+\b', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        ranges.add((match.start, match.end));
      }
    }
    final valuePatterns = <RegExp>[
      RegExp(
        r'\b(?:rename\s+[A-Za-z][A-Za-z0-9_.-]*\s+to|(?:named|called|hostname))\s+([A-Za-z][A-Za-z0-9_.-]*)',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:\b(?:ssid|network\s+name)|اسم\s+الشبك[ةه])\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\r\n,;`"\x27]+)',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:\b(?:password|passphrase|secret|psk|pre-shared\s+key)|كلم[ةه]\s+(?:المرور|السر))\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\s,;`"\x27]+)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in valuePatterns) {
      for (final match in pattern.allMatches(text)) {
        final rawGroup = match.group(1);
        if (rawGroup == null || rawGroup.trim().isEmpty) continue;
        final group = rawGroup.trim();
        final start = match.start + match[0]!.lastIndexOf(group);
        ranges.add((start, start + group.length));
      }
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    return ranges;
  }

  static List<(int, int)> _opaqueValueRanges(String text) {
    final ranges = <(int, int)>[];
    // Document/config quotations and file paths are data, not instructions.
    for (final pattern in [
      RegExp(r'`[^`\n]*`|"[^"\n]*"|(?<!\w)\x27[^\x27\n]*\x27'),
      RegExp(r'(?<![A-Za-z0-9])(?:[A-Za-z]:[\\/]|\\\\|/)[^\s,;]+'),
    ]) {
      for (final match in pattern.allMatches(text)) {
        ranges.add((match.start, match.end));
      }
    }
    final patterns = <RegExp>[
      RegExp(
        r'(?:\b(?:ssid|network\s+name)|اسم\s+الشبك[ةه])\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\r\n,;`"\x27]+)',
        caseSensitive: false,
      ),
      RegExp(
        r'(?:\b(?:password|passphrase|secret|psk|pre-shared\s+key)|كلم[ةه]\s+(?:المرور|السر))\s*(?::|=|\bis\b)?\s*[`"\x27]?([^\s,;`"\x27]+)',
        caseSensitive: false,
      ),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(text)) {
        final rawValue = match.group(1);
        if (rawValue == null || rawValue.trim().isEmpty) continue;
        final value = rawValue.trim();
        final start = match.start + match[0]!.lastIndexOf(value);
        ranges.add((start, start + value.length));
      }
    }
    return ranges;
  }

  NormalizedMessage finish() {
    final segments = <NormalizationSegment>[];
    final opaqueBoundaries = {
      for (final range in _opaque) ...[range.$1, range.$2],
    };
    var i = 0;
    while (i < text.length) {
      final begin = i;
      final sourceStart = _starts[i];
      var sourceEnd = _ends[i];
      final copied = sourceEnd == sourceStart + 1;
      i++;
      while (i < text.length) {
        final previousStart = _starts[i - 1];
        final currentStart = _starts[i];
        final currentEnd = _ends[i];
        final joinsCopy =
            copied &&
            currentEnd == currentStart + 1 &&
            currentStart == previousStart + 1 &&
            !opaqueBoundaries.contains(currentStart);
        final joinsReplacement =
            !copied && currentStart == sourceStart && currentEnd == sourceEnd;
        if (!joinsCopy && !joinsReplacement) break;
        if (joinsCopy) sourceEnd = currentEnd;
        i++;
      }
      final normalizedLength = i - begin;
      final sourceLength = sourceEnd - sourceStart;
      final kind = copied && normalizedLength == sourceLength
          ? NormalizationSegmentKind.copied
          : normalizedLength > sourceLength
          ? NormalizationSegmentKind.expansion
          : NormalizationSegmentKind.replacement;
      segments.add(
        NormalizationSegment(
          normalizedStart: begin,
          normalizedEnd: i,
          originalStart: sourceStart,
          originalEnd: sourceEnd,
          kind: kind,
        ),
      );
    }
    segments.addAll(
      _deletions.map(
        (item) => NormalizationSegment(
          normalizedStart: item.at,
          normalizedEnd: item.at,
          originalStart: item.start,
          originalEnd: item.end,
          kind: NormalizationSegmentKind.deletion,
        ),
      ),
    );
    segments.sort((a, b) {
      final offset = a.normalizedStart.compareTo(b.normalizedStart);
      return offset != 0 ? offset : a.originalStart.compareTo(b.originalStart);
    });
    return NormalizedMessage(
      originalText: _original,
      normalizedText: text,
      segments: segments,
      opaqueSourceRanges: _opaque,
    );
  }
}

/// Does this brief name a device kind (or an explicit device label like
/// R1/PC3) anywhere? Derived from [deviceKinds] so it cannot drift from the
/// parser's own vocabulary.
///
/// Used to tell "a new lab that names no devices" (where the parser's
/// router+switch fallback is right) apart from "a short follow-up like
/// 'ok build the packet tracer file'" - where inventing a default lab would
/// silently REPLACE the plan built from the user's real request.
final RegExp namesAnyDevice = RegExp(
  '(?:\\b(?:'
  '${deviceKinds.expand((k) => k.keywords)
  // Plural-tolerant: "2 routers" must count, and \brouter\b alone
  // would not match it.
  .map((k) => '${RegExp.escape(k)}(?:es|s)?').join('|')}'
  ')\\b)',
);

final RegExp _deviceLabel = RegExp(
  r'\b(?:R|SW|PC|SRV)\d{1,2}\b',
  caseSensitive: false,
);

/// True when [lower] mentions a device kind or a label like R1 / SW2 /
/// PC3 / SRV1. Pure; see [namesAnyDevice].
bool namesAnyDeviceIn(String lower) =>
    namesAnyDevice.hasMatch(lower) || _deviceLabel.hasMatch(lower);

/// A server label whose name says which service it runs: DHCP1, DNS1,
/// WEB1, AAA1, FTP1, MAIL1, NTP1 ...

/// An explicitly named lab/project wins over a conversation fallback.
RegExpMatch? projectNameMention(String text) => RegExp(
  r'\b(?:lab|project|topology|network)\s+(?:named|called)\s+'
  r'(?:`([^`\r\n]+)`|"([^"\r\n]+)"|\x27([^\x27\r\n]+)\x27|([A-Za-z][A-Za-z0-9_.-]*))',
  caseSensitive: false,
).firstMatch(text);

String? explicitProjectName(String text) {
  final mention = projectNameMention(text);
  if (mention == null) return null;
  for (var group = 1; group <= 4; group++) {
    if (mention.group(group) != null) return mention.group(group)!.trim();
  }
  return null;
}

/// The learned-phrasing hop, run once at the top of every parse.
NetworkIntent parseBrief(String projectName, String rawText) {
  projectName = explicitProjectName(rawText) ?? projectName;
  final request = PtBriefRequest.read(rawText);
  return request.apply(
    _parseGeneralBrief(
      projectName,
      request.plannerText,
      request.routerModelHint,
    ),
  );
}

Map<String, dynamic> _parseInBackground(List<String> request) =>
    parseBrief(request[0], request[1]).toJson();

Future<NetworkIntent> parseBriefAsync(
  String projectName,
  String rawText,
) async {
  if (rawText.length < 1200) return parseBrief(projectName, rawText);
  // Learned phrasing belongs to the main session's index. Preserve its
  // existing one-hop behavior when a stored correction applies.
  if (PhrasingMemoryService.lookupMatch(bridgeBrief(rawText)) != null) {
    return parseBrief(projectName, rawText);
  }
  return NetworkIntent.fromJson(
    await compute(_parseInBackground, [projectName, rawText]),
  );
}

/// The legacy service-slot reader treats a role word as positive inventory.
/// Mask only explicitly negated service noun phrases for that reader. The
/// source-mapped bridge itself retains the negative clause for requirements.
String _serviceSafePlannerText(String text) {
  final normalized = bridgeBriefWithMapping(text);
  final source = normalized.normalizedText;
  final units = source.codeUnits.toList();
  final cuePattern = RegExp(
    r'\b(?:without|no|exclude|do\s+not|don.t|never)\s+'
    r'(?:(?:add|use|enable|include|create)\s+)?',
    caseSensitive: false,
  );
  final boundary = RegExp(
    r'[,;.\n]|\b(?:but|however)\b|\band\s+(?:add|use|enable|put|set|change|keep)\b',
    caseSensitive: false,
  );
  for (final cue in cuePattern.allMatches(source)) {
    final stop = boundary.firstMatch(source.substring(cue.end));
    final end = stop == null ? source.length : cue.end + stop.start;
    final clause = source.substring(cue.end, end);
    if (normalized.overlapsOpaqueSource(start: cue.start, end: cue.end)) {
      continue;
    }
    // Carry the negative verb until the next action, not through an unrelated
    // condition such as "no need to change DHCP" or "no need for a DNS change".
    if (!RegExp(
      r'^(?:a\s+|an\s+|the\s+)?(?:dns|dhcp|https?|web|ftp|tftp|ntp|snmp|syslog|aaa|tacacs|radius)\b',
      caseSensitive: false,
    ).hasMatch(clause)) {
      continue;
    }
    for (final service in RegExp(
      r'\b(?:dns|dhcp|http|https|web|ftp|tftp|ntp|snmp|syslog|aaa|tacacs|radius)'
      r'(?:\s+servers?)?\b',
      caseSensitive: false,
    ).allMatches(clause)) {
      final start = cue.end + service.start;
      final finish = cue.end + service.end;
      if (normalized.overlapsOpaqueSource(start: start, end: finish)) continue;
      for (var i = start; i < finish; i++) {
        units[i] = 32;
      }
    }
  }
  return String.fromCharCodes(units);
}

NetworkIntent _parseGeneralBrief(
  String projectName,
  String rawText,
  String? routerModelHint,
) {
  final bridged = _serviceSafePlannerText(rawText);
  // Learned phrasing: when this exact wording was clarified before, the
  // resolved brief replays - the parser reads it as if the user had typed
  // it. Exactly one hop: a replay is never looked up again, so the index
  // can never loop. A brief that already states device counts is skipped
  // inside lookupMatch() and stays as written.
  final replay = PhrasingMemoryService.lookupMatch(bridged);
  if (replay != null &&
      replay.rewrite.trim().isNotEmpty &&
      replay.rewrite != bridged) {
    if (replay.exact) {
      return NetworkIntent.parseBridged(
        projectName,
        _serviceSafePlannerText(replay.rewrite),
        rawText,
      );
    }
    // A NEAR TWIN is not the same request: the wording differs exactly
    // where the user said something new. The remembered resolution is
    // read FIRST (the parser reads the first count per kind), and the
    // user's own words stay whole after it, so any device, service, site,
    // address, model or constraint named in this message survives the
    // match instead of being replaced by what was learned earlier.
    final merged = '${replay.rewrite} $bridged';
    final intent = NetworkIntent.parseBridged(
      projectName,
      _serviceSafePlannerText(merged),
      rawText,
    );
    final assumptions = [
      ...intent.assumptions,
      'Matched the phrasing "${replay.key}" remembered from an earlier '
          'conversation; it filled the details this message did not '
          'name. Everything stated here is kept as written.',
    ];
    if (replay.score >= 0.85) {
      return intent.copyWith(assumptions: assumptions);
    }
    // The match is close but not certain: say so and ask, rather than
    // letting a fuzzy memory quietly decide the plan. The merged plan is
    // still offered so the user is not left waiting.
    return intent.copyWith(
      assumptions: assumptions,
      questions: [
        ...intent.questions,
        'I matched this to an earlier phrasing ("${replay.key}"), but not '
            'with certainty - confirm it, or give the full wording once, '
            'and I will re-plan it exactly.',
      ],
      confidence: (intent.confidence - 0.1).clamp(0.0, 1.0),
    );
  }
  return NetworkIntent.parseBridged(
    projectName,
    bridged,
    rawText,
    routerModelHint,
  );
}
