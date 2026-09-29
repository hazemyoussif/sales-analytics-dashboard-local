/**
 * Page shell: language, theme, login gate, error rendering.
 * Every page mounts through here so the basis label and the auth gate are
 * impossible to forget.
 */
import { getSession, signIn, signOut, appMe, logActivity, AuthError } from './api.js';
import { DEFAULT_LANG, CURRENCY_KEY } from './config.js';
import { esc, pct, activeCurrency } from './format.js';
import {
  visiblePages, firstAllowedPage, pageKeyForHref, isProvisioned, canField, isScoped,
  tableVisible, hasSales, hasStock, TABLES
} from './perm.js';

const LANG_KEY = 'dabboos.lang';
const THEME_KEY = 'dabboos.theme';

export const t = {
  ar: {
    title: 'لوحة المنتجات — دبوس', basis: 'أساس الفواتير · بغداد',
    signin: 'دخول', signout: 'خروج', user: 'المستخدم', pass: 'كلمة المرور',
    loading: 'جارٍ التحميل…', nodata: 'لا توجد بيانات ضمن هذه الفلاتر',
    failed: 'تعذّر تحميل البيانات', lang: 'EN', from: 'من', to: 'إلى',
    curHint: 'تبديل عرض العملة — الدينار أو الدولار بسعر ثابت ١ دولار = ١٥٠٠ دينار',
    revenue: 'المبيعات (بدون ضريبة)', units: 'الكميات المباعة', margin: 'الربح',
    marginPct: 'نسبة الربح', sold: 'منتجات مُباعة', frozen: 'رأس مال مجمّد',
    topProducts: 'أعلى المنتجات', byGov: 'حسب المحافظة', allProducts: 'كل المنتجات',
    product: 'المنتج', category: 'الفئة', onhand: 'المخزون', status: 'الحالة',
    // العائلة is the part before the "/" -- هزار for هزار / جكليت. Choosing
    // one narrows الفئة to its members and, on its own, measures all of them.
    family: 'العائلة',
    multiHint: 'يمكن اختيار أكثر من فئة',
    selected: 'فئات مختارة',
    whereFrom: 'من أين جاء هذا الرقم؟',
    // What each tile actually measures. Written to be checkable in Odoo, not
    // to be reassuring: each one names the report, the filter and the field,
    // and states the limitation that would otherwise be discovered by
    // reconciling by hand for an afternoon.
    info: {
      revenue: [
        ['المصدر', 'الفواتير (Invoices) — وليس أوامر البيع (Sales Orders). لا يدخل هنا أي أمر بيع لم تُصدَر له فاتورة.'],
        ['التقرير', 'المحاسبة ← التقارير ← تحليل الفواتير'],
        ['الفلتر', 'Status = Open، وتشمل فواتير البيع وإشعارات الدائن معاً'],
        ['الحقل', 'مجموع Untaxed Amount'],
        ['ملاحظة', 'الرقم صافٍ بعد المرتجع. وهذه الصفحة تستبعد سطر [DISC] وفئتَي عارضات/استاندات، ولذلك تختلف عن «عملاء ٨٠/٢٠» التي لا تستبعد شيئاً.']
      ],
      units: [
        ['المصدر', 'الفواتير (Invoices) — وليس أوامر البيع'],
        ['التقرير', 'تحليل الفواتير، بنفس فلاتر المبيعات'],
        ['الحقل', 'مجموع Quantity'],
        ['ملاحظة', 'صافٍ بعد المرتجع. و«838/1,432» تعني: بِيع من 838 منتجاً من أصل 1,432 في الكتالوج.']
      ],
      frozen: [
        ['المصدر', 'المخزون + الفواتير معاً — ليس تقريراً واحداً في أودو'],
        ['الرصيد', 'المخزون ← المنتجات ← حقل On Hand'],
        ['القيمة', 'الرصيد × حقل Cost (التكلفة) — وليس سعر البيع Sales Price'],
        ['الشرط', 'له رصيد، ولم تُسجَّل له فاتورة منذ ٦٠ يوماً أو أكثر'],
        ['ملاحظة', 'الرصيد رصيد اليوم لا رصيد الفترة، و«آخر بيع» تاريخ عام لا يتقيّد بالفترة. ولا يتأثر بفلاتر المحافظة والمندوب والعميل لأن المخزون لا يحمل موقعاً.']
      ],
      unsold: [
        ['المصدر', 'المخزون + الفواتير معاً'],
        ['الحساب', 'نفس رأس المال المجمّد، لكن بعدد الأيام المختار في «لم تُبع منذ»'],
        ['القيمة', 'الرصيد × Cost'],
        ['ملاحظة', 'الرصيد رصيد اليوم لا رصيد الفترة']
      ],
      returned: [
        ['المصدر', 'إشعارات الدائن (Credit Notes) في الفواتير'],
        ['المعنى', 'كم رجع من المبيع — وهو مطروح أصلاً من عمودَي «الكميات المباعة» و«المبيعات»'],
        ['تنبيه', 'ليس مبلغاً يُطرح مرة أخرى. الطرح تمّ قبل أن ترى الأرقام.'],
        ['الشرطة', '«—» تعني لا مرتجع لهذا المنتج في الفترة، لا صفر مجهول']
      ],
      onhand: [
        ['المصدر', 'المخزون ← المنتجات ← حقل On Hand في أودو'],
        ['الوقت', 'رصيد اليوم — لا رصيد الفترة المختارة. أودو لا يحتفظ برصيد كل يوم.'],
        ['الوحدة', 'بوحدة قياس المنتج نفسه، ولهذا تظهر أحياناً كسور']
      ],
      lastSale: [
        ['المصدر', 'تاريخ آخر فاتورة للمنتج — على الإطلاق، لا داخل الفترة المختارة'],
        ['تنبيه', 'لذلك قد يظهر تاريخ بعد نهاية الفترة التي اخترتها، وعدد أيام الركود قد يخرج بالسالب']
      ],
      abc: [
        ['المعنى', 'حصة المنتج من إيراد الفترة، تراكمياً'],
        ['الحدود', 'A = أعلى ٨٠٪ من الإيراد · B = الـ١٥٪ التالية · C = الذيل'],
        ['ملاحظة', 'محسوب على كل المنتجات التي تطابق الفلاتر، لا على الصفوف الظاهرة فقط. ولا علاقة له بتصنيف A/B/C للعملاء في صفحة ٨٠/٢٠ — ذاك شرائح ثابتة من ٢٠٢٥.']
      ]
    },
    lastSale: 'آخر بيع', search: 'بحث', gov: 'المحافظة', city: 'المدينة', rep: 'المندوب',
    // The returned columns are a BREAKDOWN of the two beside them, not an
    // extra deduction: "الكميات المباعة" and "المبيعات" are already net of
    // returns. Anyone subtracting these again gets a number that is too low,
    // so the note under the table says which way round it is.
    returnedUnits: 'كمية المرتجع', returnedValue: 'قيمة المرتجع',
    returnsNote: 'الكميات والمبيعات صافية بعد المرتجع. عمودا المرتجع يوضّحان كم رجع، وليسا مبلغاً يُطرح مرة أخرى.',
    abcHelp: 'ABC = حصة المنتج من المبيعات. A = أعلى 80% من الإيراد · B = الـ15% التالية · C = الذيل',
    nav: { overview: 'نظرة عامة', products: 'كل المنتجات', status: 'حالة المنتجات',
           returns: 'المرتجعات', discounts: 'الخصومات',
           customers: 'عملاء 80/20', agencies: 'التوكيلات',
           debt: 'الديون', branches: 'المخازن', warehouses: 'المخازن',
           expiry: 'الصلاحية',
           frozen: 'رأس مال مجمّد', reorder: 'إعادة الطلب',
           sync: 'حالة المزامنة', admin: 'الإدارة' },
    notProvisioned: 'لم يتم تفعيل حسابك',
    notProvisionedHelp:
      'تم تسجيل دخولك بنجاح، لكن لم يُمنح هذا الحساب أي صلاحية بعد. ' +
      'راجع مدير النظام. هذه ليست مشكلة في البيانات.',
    noPages: 'لا توجد صفحات متاحة لدورك. راجع مدير النظام.',
    scopedNotice: 'أنت ترى جزءاً من البيانات فقط',
    // Deliberately says "not available to your role", never "no data": a
    // withheld number and a missing number look identical on screen otherwise.
    unavailable: 'هذه البيانات غير متاحة لدورك',
    unavailableSales: 'بيانات المبيعات غير متاحة لدورك — راجع مدير النظام',
    unavailableStock: 'بيانات المخزون غير متاحة لدورك — راجع مدير النظام',
    // Shown on the stock tiles only while a محافظة / مدينة / مندوب / عميل
    // filter is active. The rest of the page narrows; these two cannot,
    // because the synced stock has no location on it.
    companyWide: '⚠ على مستوى الشركة — لا يتأثر بفلاتر المحافظة والمندوب والعميل',
    customer: 'العميل', all: 'الكل', showing: 'يُعرض', of: 'من', skuUnit: 'منتج',
    outOfStock: 'نفد من المخزن', sellingNoStock: 'يُباع ولا يوجد رصيد',
    untaxed: 'بدون ضريبة',
    perCarton: 'كرتونة', perPiece: 'فرد',
    packUnknown: 'حجم العبوة غير معروف',
    packFill: 'حجم العبوة معروف لـ',
    neverSoldTitle: 'منتجات بلا مبيعات',
    agency: 'التوكيل', daysUnit: 'يوم',
    unsoldFor: 'لم تُبع منذ',
    unsoldTitle: 'منتجات لم تُبع خلال',
    unsoldSubA: 'منتجات لديها رصيد في المخزن ولم تُبع خلال آخر',
    unsoldSubB: '— مرتّبة بقيمة المخزون، وهذا ترتيب التنفيذ',
    // NOT "never sold". The invoice table only holds what the backfill covers,
    // and a product that last sold before that window looks identical to one
    // that never sold at all. Confirmed on a real product: فطائر كاستون تارت
    // sold 78 units in December 2025 and shows here as never sold. Calling
    // that "لم تُبع أبداً" would send someone to liquidate seasonal stock.
    neverSoldSub: 'لا توجد لها فاتورة ضمن البيانات المتاحة',
    neverSoldSince: 'لا توجد لها أي فاتورة منذ',
    neverSoldWarn: 'قد تكون بيعت قبل هذا التاريخ — البيانات لا تصل إلى ما قبله',
    sales: {
      active: 'نشط', idle: 'راكد', stalled: 'شبه متوقف', out: 'منتهي من المخزن'
    },
    salesHelp: {
      active: 'باع خلال آخر شهر',
      idle: 'لم يبع خلال آخر شهر',
      stalled: 'لم يبع خلال آخر ٣ شهور',
      out: 'الرصيد صفر أو أقل'
    },
    // Card headings, filled into the HTML by applyStaticTranslations().
    pg: {
      topProducts: 'أعلى المنتجات', topProductsSub: 'حسب المبيعات بدون ضريبة، بعد خصم المرتجع',
      topProductsSubUnits: 'حسب الكميات المباعة، بعد خصم المرتجع',
      categories: 'الفئات', categoriesSub: 'حصة كل فئة من المبيعات',
      products: 'المنتجات', productsSub: 'أعلى 60 منتج · ABC = حصة المنتج من الإيراد (A = أعلى 80%)',
      allProducts: 'كل المنتجات',
      aging: 'مدة الركود', agingSub: 'منذ متى والمال محتجز، وكم في كل فترة',
      byCategory: 'حسب الفئة', byCategorySub: 'قيمة المخزون المجمّد — أعلى 10 فئات',
      byBrand: 'حسب الماركة', byBrandSub: 'الماركة مسجّلة على 67% من السطور — غير المسجّل يُجمع تحت «—»',
      liquidation: 'قائمة التصفية', liquidationSub: 'الأكبر مالاً أولاً — وهذا ترتيب التنفيذ',
      runningOut: 'على وشك النفاد', runningOutSub: 'أيام التغطية المتبقية ← الكمية المقترحة',
      orderValue: 'قيمة الشراء حسب الفئة', orderValueSub: 'تكلفة الكمية المقترحة بسعر التكلفة الحالي',
      purchase: 'قائمة الشراء', purchaseSub: 'المنتجات التي تُباع فعلاً فقط',
      status: 'حالة المنتجات', statusSub: 'حسب تاريخ آخر بيع — من ما زال يتحرك ومن توقف'
    },
    cols: {
      sku: 'الكود', name: 'المنتج', category: 'الفئة', brand: 'الماركة',
      units: 'الكميات', revenue: 'المبيعات', margin_pct: 'نسبة الربح',
      realized_price: 'السعر', on_hand: 'المخزون', cover: 'التغطية (يوم)',
      velocity_90d: 'وحدة/شهر', last_invoiced: 'آخر بيع', abc: 'ABC', status: 'الحالة',
      pieces: 'الكمية بالفرد'
    },
    ret: {
      title: 'المرتجعات', sub: 'ما رجع من البضاعة — مخفي داخل الأرقام الأخرى لأنه يُخصم منها',
      returnedUnits: 'كميات مرتجعة', returnedValue: 'قيمة المرتجع',
      rate: 'نسبة الإرجاع', soldUnits: 'الكميات المباعة', soldValue: 'المبيعات',
      returnInvoices: 'فواتير إرجاع', topProducts: 'أكثر المنتجات إرجاعاً',
      byCustomer: 'حسب العميل', bySalesperson: 'حسب المندوب',
      byGov: 'حسب المحافظة', byCategory: 'حسب الفئة',
      rateHelp: 'نسبة الإرجاع = الكميات المرتجعة ÷ الكميات المباعة في نفس الفترة',
      noReturns: 'لا توجد مرتجعات ضمن هذه الفلاتر — وهذا خبر جيد'
    },
    // ---- the four management pages -------------------------------------
    cust: {
      dept: 'القسم', customer: 'العميل', customers: 'عدد العملاء',
      customersWord: 'عميل', class: 'الفئة', segment: 'القسم', invoices: 'الفواتير',
      classA: 'في الفئة A', carry80: 'يصنعون 80% من المبيعات',
      ofCustomers: 'من إجمالي العملاء', ofRevenue: 'من المبيعات',
      revenueA: 'مبيعات الفئة A', topCustomer: 'أكبر عميل',
      // The three things a reader of this page gets wrong: that it excludes
      // what Overview excludes (it does not), that A/B/C describes this month
      // (it describes 2025), and that the 2025 column is last year's total
      // (it covers only customers who also bought this month).
      info: {
        customers: [
          ['المصدر', 'الفواتير (Invoices) — وليس أوامر البيع'],
          ['التقرير', 'تحليل الفواتير، Status = Open، مجمّعاً حسب Customer'],
          ['التعريف', 'عميل له فاتورة واحدة على الأقل في الشهر المختار'],
          ['ملاحظة', 'هذه الصفحة لا تستبعد شيئاً — لا [DISC] ولا عارضات/استاندات — فإجماليها يطابق أودو الخام تماماً، بخلاف «نظرة عامة».']
        ],
        carry80: [
          ['المصدر', 'محسوب في هذه الصفحة — لا يوجد ما يقابله في أودو'],
          ['الحساب', 'رتّب العملاء تنازلياً بالمبيعات، ثم اجمع حتى تبلغ ٨٠٪ من مبيعات الشهر'],
          ['المعنى', 'أقل عدد من العملاء يصنعون ٨٠٪ من مبيعات الشهر']
        ],
        revenueA: [
          ['المصدر', 'مبيعات الشهر المختار من الفواتير'],
          ['التصنيف', 'ليس حصة هذا الشهر. A و B و C شرائح ثابتة من متوسط المبيعات الشهري في ٢٠٢٥'],
          ['الحدود', 'A فوق مليون تقريباً · B بين ٤٠٠ ألف ومليون · C أقل'],
          ['ملاحظة', 'لذلك قد يظهر عميل A بمبيعات صغيرة هذا الشهر — وهذا هو المقصود: عميل كبير تراجع.']
        ],
        topCustomer: [
          ['المصدر', 'الفواتير (Invoices)'],
          ['للتحقق', 'تحليل الفواتير ← Status = Open ← الشهر نفسه ← جمِّع حسب Customer ورتّب تنازلياً'],
          ['النسبة', 'حصته من مبيعات الشهر']
        ],
        compare: [
          ['التغطية', 'عملاء هذا الشهر فقط'],
          ['المعنى', 'من اشترى في الشهر نفسه العام الماضي ولم يشترِ هذا الشهر لا يظهر له صف'],
          ['تنبيه', 'الرقم صحيح لكل عميل على حدة، لكن مجموع العمود أقل من مبيعات ذلك الشهر الحقيقية ولا يصلح كإجمالي للعام الماضي.']
        ],
        growth: [
          ['الحساب', '(هذا الشهر − الشهر المقارَن) ÷ الشهر المقارَن × ١٠٠'],
          ['شرطة', 'تظهر «—» عندما لا يوجد ما يُقاس عليه: عميل جديد لم يشترِ في الفترة السابقة ليس نموّه ٠٪ ولا ∞، بل لا نمو له.'],
          ['الأساس', 'يتغيّر بتغيير «المقارنة على أساس»: مبيعات أو ربح أو كميات أو فواتير']
        ],
        avgMonthly: [
          ['المصدر', 'متوسط مبيعات العميل الشهرية في ٢٠٢٥'],
          ['الحساب', 'إجمالي مبيعاته في ٢٠٢٥ ÷ ١٢'],
          ['الغرض', 'هذا هو الرقم الذي اشتُقّ منه حرف A / B / C، معروضاً كي لا يُؤخذ الحرف على عهدة أحد']
        ],
        lastPurchase: [
          ['المصدر', 'آخر فاتورة للعميل — على الإطلاق، لا داخل الشهر المختار'],
          ['الدقّة', 'بالشهر لا باليوم: «١ أغسطس» تعني «آخر شراء في أغسطس»'],
          ['تنبيه', 'قد يصل الفرق إلى ٣٠ يوماً، ولذلك يظهر أحياناً تاريخ بعد نهاية الشهر المختار']
        ]
      },
      shareOfRevenue: 'الحصة', shareOfCustomers: 'نسبة العملاء',
      cumShare: 'الحصة التراكمية', daysAgo: 'يوم',
      lastPurchase: 'آخر شراء',
      cumHelp: 'مجموع حصص هذا العميل ومن قبله. عندما يصل إلى 80% نكون قد عدّدنا العملاء الذين تعتمد عليهم الشركة.',
      curveTitle: 'منحنى التركّز — كم عميلاً تعتمد عليه الشركة فعلاً',
      curveSub: 'المحور الأفقي: نسبة العملاء من الأكبر إلى الأصغر. المحور الرأسي: نسبتهم التراكمية من المبيعات. الخط المتقطع المائل هو شكل التوزيع لو كان كل العملاء متساوين — والمسافة بينه وبين المنحنى هي التركّز نفسه.',
      classesTitle: 'الفئات A / B / C',
      classesSub: 'حسب متوسط المبيعات الشهرية لعام ٢٠٢٥ — الحرف ثابت ولا يتغيّر بالشهر المعروض، والأعداد تتبع فلاتر القسم/المحافظة/المندوب',
      classHelp: { A: 'مليون دينار شهرياً فأكثر', B: '٤٠٠ ألف — مليون شهرياً',
                   C: 'أقل من ٤٠٠ ألف شهرياً' },
      avgMonthly: 'متوسط شهري ٢٠٢٥',
      revenue2025: 'مبيعات ٢٠٢٥ (بدون ضريبة)',
      topTitle: 'أكبر 12 عميلاً', byGovTitle: 'المبيعات حسب المحافظة',
      byDeptTitle: 'المبيعات حسب قسم العميل',
      byDeptSub: 'حسب حقل Title في أودو — ماركتات · كرزات · جملة · سلاسل كبرى. العملاء بلا تصنيف يظهرون تحت «—».',
      tableTitle: 'كل العملاء مرتبين بالحصة',
      showAll: 'عرض كل العملاء',
      measure: 'المقارنة على أساس',
      measures: { revenue: 'المبيعات', margin: 'الربح', units: 'الكميات', invoices: 'الفواتير' },
      periodTitle: 'الشهر',
      periodMonth: 'الشهر',
      periodHint: 'اختر شهراً واحداً. كل الأرقام في الصفحة محسوبة عليه، ثم اختر بمَ يُقارَن.',
      compare: { lastYear: 'نفس الشهر من السنة الماضية', prevMonth: 'الشهر السابق' },
      versus: 'مقابل',
      legend: 'كيف تُقرأ هذه الصفحة:',
      legendA: 'A — لو خسرنا واحداً منهم يظهر الأثر في الميزانية فوراً. يستحقون مراجعة أسعار وخدمة خاصة.',
      legendB: 'B — قاعدة قابلة للنمو: أقرب مصدر لزيادة المبيعات دون عميل جديد.',
      legendC: 'C — كثيرون وأثرهم صغير. الهدف هنا خفض تكلفة الخدمة، لا زيادة الاهتمام.'
    },
    agn: {
      agency: 'التوكيل', agencies: 'التوكيلات', product: 'المنتجات',
      allAgencies: 'كل التوكيلات',
      family: 'العائلة', units: 'الكمية المباعة', unitShare: 'حصة الكمية',
      families: 'عدد العائلات', products: 'الأصناف', skus: 'عدد الأصناف',
      sold: 'صنف مباع',
      familiesTitle: 'العائلات حسب الكمية المباعة',
      familiesSub: 'مجمّعة على مستوى العائلة (هزار، لا هزار / جكليت) — مرتبة تنازلياً بالكمية',
      unsoldTitle: 'أصناف غير مباعة ومتوفرة بالمخزن',
      unsoldSub: 'لم تُبَع خلال المدة المختارة ولها رصيد — تتغيّر مع فلتر العائلة والتوكيل',
      titleNote: 'فلتر «القسم» يصفّي على تصنيف العميل من أودو (حقل Title): ماركتات · كرزات · جملة · سلاسل كبرى',
      info: {
        units: [['المصدر', 'الفواتير المجمّعة شهرياً حسب المنتج (dashboard_product_month)، أو سطور الفواتير عند اختيار قسم/مندوب'],
                ['التعريف', 'إجمالي الكمية المباعة (صافي المرتجع) ضمن الفلترة الحالية']],
        revenue: [['المصدر', 'نفس مصدر الكمية'],
                  ['التعريف', 'المبيعات بدون ضريبة، صافي المرتجع']],
        families: [['المصدر', 'محسوب من فئة المنتج في أودو (هزار / جكليت ← هزار)'],
                   ['التعريف', 'عدد العائلات التي لها مبيعات ضمن الفلترة']],
        products: [['المصدر', 'كتالوج المنتجات في أودو'],
                   ['التعريف', 'عدد الأصناف ضمن الفلترة · «صنف مباع» منها ما تحرّك فعلاً']]
      }
    },
    debt: {
      customer: 'العميل', customers: 'عميل', days: 'يوم',
      totalAr: 'إجمالي الذمم', overdue: 'المتأخر', balance: 'الرصيد',
      ofBalance: 'من إجمالي الذمم',
      avgPastDue: 'متوسط التأخر', avgPastDueNote: 'مرجّح بالمبلغ، لا بعدد العملاء',
      avgTerms: 'متوسط فترة السداد المتفق عليها', avgTermsNote: 'مرجّح بالرصيد',
      overLimit: 'تجاوزوا الحد الائتماني',
      terms: 'فترة السداد', oldest: 'أقدم فاتورة', pastDue: 'أيام التأخر',
      pastDueHelp: 'أيام التأخر = عمر أقدم فاتورة ناقص فترة السداد المتفق عليها مع هذا العميل — لا 30 يوماً ثابتة للجميع',
      bucket: 'شريحة التأخر', limit: 'الحد الائتماني', utilisation: 'استغلال الحد',
      avgPay: 'متوسط سداده الفعلي',
      avgPayHelp: 'متوسط عدد الأيام التي يستغرقها هذا العميل فعلياً حتى السداد',
      buckets: { 'current': 'غير مستحق', '1-30': 'متأخر 1-30', '31-60': 'متأخر 31-60',
                 '61-90': 'متأخر 61-90', '90+': 'متأخر +90' },
      agingTitle: 'أعمار الديون',
      agingSub: 'الجزء غير المستحق من رصيد العميل يبقى «غير مستحق» حتى لو تأخر باقيه — الرصيد يُقسَّم ولا يُصنَّف كله بعمر أقدم فاتورة فيه',
      byGovTitle: 'المتأخر حسب المحافظة',
      byRepTitle: 'المتأخر حسب المندوب',
      byRepSub: 'التحصيل مسؤولية لها اسم',
      watchTitle: 'قائمة المراقبة',
      watchSub: 'من تجاوز حده الائتماني أو تأخر أكثر من 90 يوماً — مرتبين بالمبلغ المتأخر',
      noWatch: 'لا أحد ضمن هذه الفلاتر تجاوز حده أو تأخر أكثر من 90 يوماً',
      flag: 'التنبيه', flagOverLimit: 'فوق الحد', flag90: '+90 يوم',
      tableTitle: 'كل العملاء',
      footnoteTitle: 'ما تحتاجه هذه الصفحة من أودو لتصبح حقيقية:',
      footnote1: 'تاريخ استحقاق الفاتورة (invoice_date_due) — موجود في تقرير الفواتير ولم يُضف إلى المزامنة بعد. بدونه لا توجد شرائح تأخر إطلاقاً.',
      footnote2: 'المتبقي على كل فاتورة (amount_residual) وفترة السداد المتفق عليها — يحتاجان مزامنة جديدة من account.move و res.partner.'
    },
    br: {
      warehouse: 'المخزن', product: 'المنتج', agency: 'التوكيل', days: 'يوم',
      revenue: 'مبيعات الفرع', lastMonth: 'آخر 30 يوماً',
      stockValue: 'قيمة المخزون في الفرع',
      medianCover: 'وسيط أيام التغطية', coverNote: 'الوسيط لا المتوسط — صنف واحد راكد لا يزيّن الرقم',
      stockouts: 'نفد وهو يُباع', stockoutsNote: 'رصيد صفر مع طلب قائم — الخسارة الوحيدة التي لا تظهر في أي تقرير',
      onHand: 'الرصيد', cover: 'أيام التغطية', soldMonth: 'مبيعات الشهر',
      coverHelp: 'أيام التغطية = الرصيد ÷ معدل البيع اليومي. «لا يُباع» ليست صفراً — هي مشكلة أخرى.',
      notSelling: 'لا يُباع',
      trendTitle: 'مبيعات الفرع شهرياً',
      trendSub: 'آخر 12 شهراً',
      transfersTitle: 'مقترحات المناقلة بين المخزنين',
      transfersSub: 'صنف يوشك على النفاد هنا ومكدّس في الفرع الآخر. الكمية المقترحة تعيد تغطية 60 يوماً هنا ولا تتجاوز نصف رصيد الفرع الآخر — مناقلة تصنع نفاداً هناك لم تحل شيئاً.',
      noTransfers: 'لا توجد مناقلة مجدية الآن — لا يوجد صنف ناقص هنا وفائض هناك',
      stockoutsTitle: 'نفد من هذا المخزن وهو يُباع',
      stockoutsSub: 'مرتبة بحجم الطلب الضائع',
      topTitle: 'أعلى الأصناف مبيعاً في الفرع',
      tableTitle: 'مخزون الفرع',
      here: 'الرصيد هنا', there: 'الرصيد هناك',
      coverHere: 'تغطية هنا', coverThere: 'تغطية هناك', move: 'الكمية المقترحة',
      moveHelp: 'ما يكفي لإعادة تغطية 60 يوماً في هذا الفرع، وبحد أقصى نصف رصيد الفرع الآخر',
      pageTitle: 'المخازن', pageSub: 'المتاح للاستخدام في كل مخزن — لقطة حالية، تُحدَّث مع المزامنة',
      skus: 'عدد الأصناف', value: 'قيمة المخزون', category: 'التوكيل',
      free: 'المتاح للاستخدام', reservedWord: 'محجوز',
      allWarehouses: 'كل المخازن', byWhTitle: 'المتاح حسب المخزن',
      stockTableTitle: 'الأصناف المتوفرة',
      pending: 'بيانات المخازن لم تُزامَن بعد. شغِّل مزامنة المخزون (odoosync branch-stock) وستظهر الأرقام هنا.',
      within: 'قرب الانتهاء خلال',
      expiryTitle: 'صلاحية الأصناف',
      expirySub: 'الأصناف المتتبَّعة باللوت والموجودة بالمخزن، مرتبة بأقرب تاريخ انتهاء. الصلاحية مسجّلة على اللوت في أودو، فلا تظهر هنا الأصناف غير المتتبَّعة باللوت.',
      expiryEmpty: 'لا توجد أصناف متتبَّعة باللوت ضمن هذه الفلاتر — أو مزامنة الصلاحية (odoosync expiry) لم تُشغَّل بعد.',
      expired: 'منتهية الصلاحية',
      expSoon: 'تنتهي خلال {n} يوم',
      expTracked: 'إجمالي المتتبَّع باللوت',
      earliest: 'أقرب انتهاء',
      info: {
        skus: [['المصدر', 'مخزون أودو لكل مخزن — stock.quant في المواقع الداخلية'],
               ['التعريف', 'عدد الأصناف التي لها رصيد في المخزن (أو في كل المخازن)'],
               ['ملاحظة', 'يستبعد العارضات والاستاندات و[DISC] مثل باقي الصفحات، ويتأثر بفلاتر العائلة/التوكيل/المنتج']],
        free: [['المصدر', 'stock.quant — الكمية ناقص المحجوز (reserved_quantity)'],
               ['التعريف', 'المتاح للبيع فعلاً. الكمية المحجوزة مرتبطة بأوامر قائمة ولا تُحسب هنا'],
               ['ملاحظة', 'الرقم تحت التايل هو إجمالي المحجوز ضمن نفس الفلترة']],
        value: [['المصدر', 'الكمية المتاحة × سعر التكلفة (standard_price) من أودو'],
                ['التعريف', 'قيمة المتاح للاستخدام بسعر التكلفة، لا بسعر البيع']],
        expired: [['المصدر', 'stock.lot.expiration_date × الرصيد على اللوت من stock.quant'],
                  ['التعريف', 'كمية اللوتات التي تجاوز تاريخ انتهائها تاريخ اليوم وما زالت بالمخزن'],
                  ['ملاحظة', 'التاريخ في أودو datetime؛ تُقصّ إلى يوم فقط عند المزامنة']],
        expSoon: [['التعريف', 'كمية اللوتات التي تنتهي بين اليوم ونهاية المدة المختارة (٣٠/٦٠/٩٠/١٨٠ يوم)'],
                  ['ملاحظة', 'لا تشمل المنتهية بالفعل — تلك في تايل «منتهية الصلاحية»']],
        expTracked: [['التعريف', 'إجمالي الكمية على كل اللوتات المؤرَّخة ضمن الفلترة، بصرف النظر عن تاريخ الانتهاء'],
                     ['ملاحظة', 'المنتهية + التي تنتهي خلال المدة + الأبعد = هذا الإجمالي']]
      }
    },
    disc: {
      title: 'الخصومات', sub: 'الفرق بين سعر القائمة والسعر المُحقَّق — من هنا يتسرّب الربح',
      listPrice: 'سعر القائمة', realized: 'السعر المُحقَّق', discount: 'الخصم',
      leakage: 'المتسرّب', leakageHelp: 'المتسرّب = (سعر القائمة − السعر المحقق) × الكمية',
      topLeak: 'أكبر تسرّب', topProducts: 'أكثر المنتجات تسرّباً للربح',
      byCustomer: 'حسب العميل', bySalesperson: 'حسب المندوب',
      byGov: 'حسب المحافظة', byCategory: 'حسب الفئة',
      invoiceLevel: 'خصومات على مستوى الفاتورة',
      invoiceLevelHelp: 'خصومات تُسجَّل كسطر في الفاتورة وليست على المنتج — مستبعدة من تحليل المنتجات',
      noList: 'لا يوجد سعر قائمة',
      noListHelp: 'المنتجات بلا سعر قائمة لا يمكن حساب خصمها — تظهر بـ «—» وليس صفر'
    },
    detail: {
      close: 'إغلاق', customers: 'العملاء', cover: 'التغطية', days: 'يوم',
      trend: 'الاتجاه الشهري', trendSub: 'الكميات شهرياً — آخر 24 شهراً من البيانات المتاحة',
      topCustomers: 'أعلى العملاء', inPeriod: 'ضمن الفترة المحددة',
      top15of: 'أعلى 15 من', byGov: 'حسب المحافظة'
    },
    admin: {
      title: 'الإدارة', users: 'المستخدمون', roles: 'الأدوار', activity: 'النشاط',
      newUser: 'مستخدم جديد', newRole: 'دور جديد', username: 'اسم المستخدم',
      displayName: 'الاسم المعروض', role: 'الدور', scope: 'النطاق', active: 'مفعّل',
      lastSeen: 'آخر ظهور', actions: 'إجراءات', save: 'حفظ', cancel: 'إلغاء',
      del: 'حذف', password: 'كلمة المرور', setPassword: 'تغيير كلمة المرور',
      pages: 'الصفحات', hiddenCols: 'أعمدة مخفية', roleKey: 'مُعرّف الدور',
      nameAr: 'الاسم بالعربية', nameEn: 'الاسم بالإنجليزية',
      allReps: 'كل المندوبين', allGovs: 'كل المحافظات',
      scopeHelp: 'اترك الحقل فارغاً ليرى المستخدم كل شيء',
      saved: 'تم الحفظ', confirmDelete: 'تأكيد الحذف؟',
      systemRole: 'دور نظام', when: 'الوقت', event: 'الحدث', page: 'الصفحة',
      login: 'دخول', pageview: 'فتح صفحة',
      cols: { margin: 'الربح', cost: 'التكلفة', revenue: 'المبيعات',
              stock_value: 'قيمة المخزون', customers: 'أسماء العملاء' },
      tables: 'الجداول', hiddenTables: 'جداول مخفية',
      tablesHelp: 'إخفاء جدول يمنع هذا الدور من قراءته في كل صفحات اللوحة',
      tableName: 'الجدول في Supabase', feeds: 'يغذّي', provides: 'يوفّر',
      deniedPages: 'صفحات ممنوعة',
      deniedHelp: 'يمكن فقط سحب صفحة يمنحها الدور — لا يمكن منح صفحة زائدة',
      risk: { blackout: 'يُفرغ اللوحة', degrade: 'يعطّل صفحات', safe: 'أثر محدود' },
      confirmBlackout: 'هذا الدور لن يرى أي بيانات. متأكد؟',
      noPageUse: 'لا تستخدمه أي صفحة حالياً'
    },
    daysIdle: 'أيام الركود', stockValue: 'قيمة المخزون', cover: 'التغطية (يوم)',
    velocity: 'وحدة/شهر', suggested: 'الكمية المقترحة', suggestedValue: 'قيمة الشراء',
    bucket: 'مدة الركود', urgent: 'عاجل', neverSold: 'لم يُبع أبداً',
    st: {
      understock: 'أعد الطلب', dead: 'راكد', dormant: 'نائم موسمياً',
      overstock: 'مخزون زائد', healthy: 'سليم', inactive: 'غير نشط', oversold: 'رصيد سالب'
    },
    stHelp: {
      understock: 'يُباع ويكفي أقل من 30 يوماً — اشترِ الآن',
      dead: 'متوفر بالمخزن ولم يُبع منذ 60 يوماً — رأس مال مجمّد',
      dormant: 'راكد لكن موسمه لم يأتِ بعد — انتظر ولا تخفّض السعر',
      overstock: 'يكفي أكثر من 180 يوماً — أوقف الشراء',
      healthy: 'التغطية بين 30 و180 يوماً — لا إجراء',
      inactive: 'لا مخزون ولا مبيعات — لا قرار مطلوب',
      oversold: 'الرصيد سالب في أودو — خطأ محاسبي وليس قرار مخزون'
    }
  },
  en: {
    title: 'Product Dashboard — Dabboos', basis: 'Invoice basis · Baghdad',
    signin: 'Sign in', signout: 'Sign out', user: 'Username', pass: 'Password',
    loading: 'Loading…', nodata: 'No data for these filters',
    failed: 'Could not load data', lang: 'ع', from: 'From', to: 'To',
    curHint: 'Switch currency view — IQD or USD at a fixed 1 USD = 1500 IQD',
    revenue: 'Revenue (untaxed)', units: 'Units sold', margin: 'Margin',
    marginPct: 'Margin %', sold: 'Products sold', frozen: 'Frozen capital',
    topProducts: 'Top products', byGov: 'By governorate', allProducts: 'All products',
    product: 'Product', category: 'Category', onhand: 'On hand', status: 'Status',
    family: 'Family',
    multiHint: 'more than one can be picked',
    selected: 'selected',
    whereFrom: 'Where does this number come from?',
    info: {
      revenue: [
        ['Source', 'Invoices — NOT sales orders. A sales order with no invoice does not appear here.'],
        ['Report', 'Accounting → Reporting → Invoices Analysis'],
        ['Filter', 'Status = Open, covering customer invoices and credit notes together'],
        ['Field', 'Sum of Untaxed Amount'],
        ['Note', 'Net of returns. This page also excludes the [DISC] line and the عارضات/استاندات categories, which is why it differs from Customers 80/20, where nothing is excluded.']
      ],
      units: [
        ['Source', 'Invoices — not sales orders'],
        ['Report', 'Invoices Analysis, same filters as revenue'],
        ['Field', 'Sum of Quantity'],
        ['Note', 'Net of returns. "838/1,432" means 838 of the 1,432 catalogue products sold something.']
      ],
      frozen: [
        ['Source', 'Stock and invoices combined — not a single Odoo report'],
        ['Quantity', 'Inventory → Products → On Hand'],
        ['Value', 'On Hand × Cost — not the Sales Price'],
        ['Rule', 'Has stock, and no invoice for 60 days or more'],
        ['Note', 'Quantity is today’s balance, not the period’s, and "last sale" is the all-time date. Unaffected by the governorate, salesperson and customer filters, because stock carries no location.']
      ],
      unsold: [
        ['Source', 'Stock and invoices combined'],
        ['Rule', 'Same as frozen capital, using the days you pick in "not sold for"'],
        ['Value', 'On Hand × Cost'],
        ['Note', 'Quantity is today’s balance, not the period’s']
      ],
      returned: [
        ['Source', 'Credit notes within the invoices'],
        ['Meaning', 'How much came back — already subtracted from the units and revenue columns'],
        ['Warning', 'Not a further deduction. The subtraction happened before you saw the numbers.'],
        ['Dash', '"—" means no returns for this product in the period, not an unknown zero']
      ],
      onhand: [
        ['Source', 'Inventory → Products → On Hand'],
        ['Time', 'Today’s balance, not the selected period’s. Odoo keeps no daily history.'],
        ['Unit', 'In the product’s own unit of measure, which is why fractions appear']
      ],
      lastSale: [
        ['Source', 'The product’s most recent invoice — all-time, not within the selected period'],
        ['Warning', 'So a date after the end of your window can appear, and days-idle can come out negative']
      ],
      abc: [
        ['Meaning', 'The product’s cumulative share of revenue for the period'],
        ['Bands', 'A = top 80% of revenue · B = the next 15% · C = the tail'],
        ['Note', 'Computed across every product matching the filters, not just the visible rows. Unrelated to the customer A/B/C on the 80/20 page, which is a fixed 2025 tier.']
      ]
    },
    lastSale: 'Last sale', search: 'Search', gov: 'Governorate', city: 'City', rep: 'Salesperson',
    returnedUnits: 'Returned qty', returnedValue: 'Returned value',
    returnsNote: 'Units and revenue are already net of returns. The two returned columns show how much came back; they are not a further deduction.',
    abcHelp: 'ABC = share of revenue. A = top 80% · B = next 15% · C = the tail',
    nav: { overview: 'Overview', products: 'All products', status: 'Status',
           returns: 'Returns', discounts: 'Discounts',
           customers: 'Customers 80/20', agencies: 'Agencies',
           debt: 'Debt', branches: 'Warehouses', warehouses: 'Warehouses',
           expiry: 'Expiry',
           frozen: 'Frozen capital', reorder: 'Reorder',
           sync: 'Sync status', admin: 'Admin' },
    notProvisioned: 'Your account is not set up yet',
    notProvisionedHelp:
      'You signed in successfully, but this account has not been granted any ' +
      'access. Ask an administrator to set it up. This is not a data problem.',
    noPages: 'Your role has no pages assigned. Ask an administrator.',
    scopedNotice: 'You are seeing part of the data',
    // Deliberately says "not available to your role", never "no data": a
    // withheld number and a missing number look identical on screen otherwise.
    unavailable: 'This data is not available to your role',
    unavailableSales: 'Sales data is not available to your role — ask an administrator',
    unavailableStock: 'Stock data is not available to your role — ask an administrator',
    companyWide: '⚠ company-wide — not affected by the governorate, salesperson or customer filter',
    customer: 'Customer', all: 'All', showing: 'Showing', of: 'of', skuUnit: 'SKU',
    outOfStock: 'Out of stock', sellingNoStock: 'selling, nothing on hand',
    untaxed: 'untaxed',
    perCarton: 'Carton', perPiece: 'Piece',
    packUnknown: 'pack size unknown',
    packFill: 'pack size known for',
    neverSoldTitle: 'No sales on record',
    agency: 'Agency', daysUnit: 'days',
    unsoldFor: 'Not sold for',
    unsoldTitle: 'Not sold in',
    unsoldSubA: 'Products holding stock that have not sold in the last',
    unsoldSubB: '- largest stock value first, which is the order to act in',
    // NOT "never sold" — see the Arabic block above for why.
    neverSoldSub: 'No invoice within the available data',
    neverSoldSince: 'No invoice at all since',
    neverSoldWarn: 'may have sold before this date — the data does not reach further back',
    sales: {
      active: 'Active', idle: 'Idle', stalled: 'Stalled', out: 'Out of stock'
    },
    salesHelp: {
      active: 'sold within the last month',
      idle: 'no sale in the last month',
      stalled: 'no sale in the last 3 months',
      out: 'on hand is zero or less'
    },
    // Card headings, filled into the HTML by applyStaticTranslations().
    pg: {
      topProducts: 'Top products', topProductsSub: 'By untaxed revenue, net of returns',
      topProductsSubUnits: 'By units sold, net of returns',
      categories: 'Categories', categoriesSub: 'Revenue share by product category',
      products: 'Products', productsSub: 'Top 60 by revenue · ABC = share of total revenue (A = top 80%)',
      allProducts: 'All products',
      aging: 'Aging', agingSub: 'How long the money has been stuck, and how much is in each band',
      byCategory: 'By category', byCategorySub: 'Stock value frozen, top 10 categories',
      byBrand: 'By brand', byBrandSub: 'Brand is set on 67% of lines — unbranded stock is grouped as “—”',
      liquidation: 'Liquidation worklist', liquidationSub: 'Largest amount of stuck money first — that is the order to act in',
      runningOut: 'Running out first', runningOutSub: 'Days of cover remaining → suggested quantity',
      orderValue: 'Order value by category', orderValueSub: 'What the suggested purchase costs at current standard price',
      purchase: 'Purchase worklist', purchaseSub: 'Only products that are actually selling',
      status: 'Product status', statusSub: 'By last sale date — what is still moving and what has stopped'
    },
    cols: {
      sku: 'SKU', name: 'Product', category: 'Category', brand: 'Brand',
      units: 'Units', revenue: 'Revenue', margin_pct: 'Margin %',
      realized_price: 'Price', on_hand: 'On hand', cover: 'Cover (d)',
      velocity_90d: 'Units/mo', last_invoiced: 'Last sale', abc: 'ABC', status: 'Status',
      pieces: 'Pieces'
    },
    ret: {
      title: 'Returns', sub: 'What came back — invisible elsewhere because every figure nets it out',
      returnedUnits: 'Units returned', returnedValue: 'Value returned',
      rate: 'Return rate', soldUnits: 'Units sold', soldValue: 'Revenue',
      returnInvoices: 'Credit notes', topProducts: 'Most returned products',
      byCustomer: 'By customer', bySalesperson: 'By salesperson',
      byGov: 'By governorate', byCategory: 'By category',
      rateHelp: 'Return rate = units returned ÷ units sold in the same period',
      noReturns: 'No returns for these filters — which is good news'
    },
    // ---- the four management pages -------------------------------------
    cust: {
      dept: 'Department', customer: 'Customer', customers: 'Customers',
      customersWord: 'customers', class: 'Class', segment: 'Segment', invoices: 'Invoices',
      classA: 'in class A', carry80: 'Produce 80% of revenue',
      ofCustomers: 'of all customers', ofRevenue: 'of revenue',
      revenueA: 'Class A revenue', topCustomer: 'Largest customer',
      info: {
        customers: [
          ['Source', 'Invoices — not sales orders'],
          ['Report', 'Invoices Analysis, Status = Open, grouped by Customer'],
          ['Definition', 'A customer with at least one invoice in the selected month'],
          ['Note', 'This page excludes nothing — no [DISC], no عارضات/استاندات — so its total matches raw Odoo exactly, unlike Overview.']
        ],
        carry80: [
          ['Source', 'Derived on this page — Odoo has no equivalent'],
          ['Method', 'Rank customers by sales, add until 80% of the month is reached'],
          ['Meaning', 'The fewest customers who produce 80% of the month']
        ],
        revenueA: [
          ['Source', 'This month’s invoiced sales'],
          ['Class', 'Not this month’s share. A, B and C are fixed tiers from average monthly sales in 2025'],
          ['Bands', 'A above roughly 1M · B 400K to 1M · C below'],
          ['Note', 'So an A customer can show small sales this month — that is the point: a large account that has dropped.']
        ],
        topCustomer: [
          ['Source', 'Invoices'],
          ['To check', 'Invoices Analysis → Status = Open → same month → group by Customer, sort descending'],
          ['Share', 'Their share of the month’s sales']
        ],
        compare: [
          ['Covers', 'Only customers who bought this month'],
          ['Meaning', 'Anyone who bought in that month last year but not this one has no row'],
          ['Warning', 'Correct per customer, but the column sums to less than that month’s actual sales and is not a year-ago total.']
        ],
        growth: [
          ['Formula', '(this month − compared month) ÷ compared month × 100'],
          ['Dash', 'Shown when there is nothing to grow from: a new customer with no sales in the earlier period has no growth rate, neither 0% nor infinite.'],
          ['Basis', 'Follows the "Compare by" selector: revenue, margin, units or invoices']
        ],
        avgMonthly: [
          ['Source', 'The customer’s average monthly sales in 2025'],
          ['Formula', 'Their 2025 total ÷ 12'],
          ['Purpose', 'This is the number the A / B / C letter came from, shown so the letter need not be taken on trust']
        ],
        lastPurchase: [
          ['Source', 'The customer’s most recent invoice — all-time, not within the selected month'],
          ['Precision', 'Month, not day: "1 August" means "last bought in August"'],
          ['Warning', 'Can be up to 30 days out, which is why a date after the selected month sometimes appears']
        ]
      },
      shareOfRevenue: 'Share', shareOfCustomers: 'Share of customers',
      cumShare: 'Cumulative', daysAgo: 'days',
      lastPurchase: 'Last purchase',
      cumHelp: 'This customer plus everyone above them. Where it reaches 80% is where the count of customers the company depends on stops.',
      curveTitle: 'Concentration curve - how few customers carry the company',
      curveSub: 'X: share of customers, largest first. Y: their cumulative share of revenue. The dashed diagonal is what perfect equality would look like - the gap between it and the curve IS the concentration.',
      classesTitle: 'Classes A / B / C',
      classesSub: 'By average monthly sales in 2025 - the letter is fixed and does not move with the shown month; the counts follow the segment / governorate / rep filters',
      classHelp: { A: '1M IQD/month or more', B: '400k - 1M per month',
                   C: 'under 400k per month' },
      avgMonthly: 'Avg monthly 2025',
      revenue2025: '2025 sales (ex-VAT)',
      topTitle: 'Top 12 customers', byGovTitle: 'Revenue by governorate',
      byDeptTitle: 'Revenue by customer segment',
      byDeptSub: 'From the Title field in Odoo — supermarkets · kirzat · wholesale · large chains. Unclassified customers appear under "—".',
      tableTitle: 'Every customer, ranked by share',
      showAll: 'Show all customers',
      measure: 'Compare by',
      measures: { revenue: 'Revenue', margin: 'Margin', units: 'Units', invoices: 'Invoices' },
      periodTitle: 'Month',
      periodMonth: 'Month',
      periodHint: 'Pick one month. Every number on this page is measured over it. Then choose what it is compared against.',
      compare: { lastYear: 'Same month last year', prevMonth: 'Previous month' },
      versus: 'vs',
      legend: 'How to read this page:',
      legendA: 'A - losing one shows up in the budget immediately. Worth dedicated pricing and service.',
      legendB: 'B - the growable base: the cheapest revenue to win without finding a new customer.',
      legendC: 'C - many of them, little money. The goal here is cheaper service, not more attention.'
    },
    agn: {
      agency: 'Agency', agencies: 'Agencies', product: 'Products',
      allAgencies: 'All agencies',
      family: 'Family', units: 'Units sold', unitShare: 'Unit share',
      families: 'Families', products: 'Products', skus: 'SKUs',
      sold: 'sold',
      familiesTitle: 'Families by quantity sold',
      familiesSub: 'Rolled up to the family (هزار, not هزار / جكليت) — ranked by quantity',
      unsoldTitle: 'Not selling, still in stock',
      unsoldSub: 'No sale in the selected window and still holding stock — re-narrows with the family and agency filters',
      titleNote: 'The Segment filter narrows to the customer type from Odoo (Title field): supermarkets · kirzat · wholesale · large chains',
      info: {
        units: [['Source', 'Invoices rolled up monthly per product (dashboard_product_month); invoice lines when a segment or salesperson is set'],
                ['Definition', 'Total quantity sold (net of returns) under the current filters']],
        revenue: [['Source', 'Same source as the quantity'],
                  ['Definition', 'Sales ex-VAT, net of returns']],
        families: [['Source', 'Derived from the Odoo product category (هزار / جكليت → هزار)'],
                   ['Definition', 'Number of families with sales under the current filters']],
        products: [['Source', 'The Odoo product catalogue'],
                   ['Definition', 'SKUs under the current filters; "sold" is how many actually moved']]
      }
    },
    debt: {
      customer: 'Customer', customers: 'customers', days: 'days',
      totalAr: 'Total receivable', overdue: 'Overdue', balance: 'Balance',
      ofBalance: 'of the total receivable',
      avgPastDue: 'Average days past due', avgPastDueNote: 'weighted by money, not by customer count',
      avgTerms: 'Average agreed terms', avgTermsNote: 'weighted by balance',
      overLimit: 'Over their credit limit',
      terms: 'Terms', oldest: 'Oldest invoice', pastDue: 'Days past due',
      pastDueHelp: 'Days past due = age of the oldest invoice minus the terms agreed with THIS customer - not a flat 30 days for everyone',
      bucket: 'Aging bucket', limit: 'Credit limit', utilisation: 'Limit used',
      avgPay: 'Actual days to pay',
      avgPayHelp: 'How many days this customer actually takes to pay',
      buckets: { 'current': 'Not yet due', '1-30': '1-30 late', '31-60': '31-60 late',
                 '61-90': '61-90 late', '90+': '90+ late' },
      agingTitle: 'Receivables aging',
      agingSub: 'The not-yet-due part of a balance stays current even when the rest is late - a balance is split across buckets rather than filed whole under its oldest invoice',
      byGovTitle: 'Overdue by governorate',
      byRepTitle: 'Overdue by salesperson',
      byRepSub: 'Collections is a responsibility with a name on it',
      watchTitle: 'Watchlist',
      watchSub: 'Over their limit, or more than 90 days late - ranked by overdue amount',
      noWatch: 'Nobody in these filters is over their limit or more than 90 days late',
      flag: 'Flag', flagOverLimit: 'Over limit', flag90: '90+ days',
      tableTitle: 'Every customer',
      footnoteTitle: 'What this page needs from Odoo to become real:',
      footnote1: 'invoice_date_due - present in the invoice report, not yet in the sync. Without it there are no aging buckets at all.',
      footnote2: 'amount_residual per invoice and the agreed payment term - both need a new sync from account.move and res.partner.'
    },
    br: {
      warehouse: 'Warehouse', product: 'Product', agency: 'Agency', days: 'days',
      revenue: 'Branch revenue', lastMonth: 'last 30 days',
      stockValue: 'Stock value at this branch',
      medianCover: 'Median days of cover', coverNote: 'median, not mean - one dead item cannot flatter it',
      stockouts: 'Out of stock while selling', stockoutsNote: 'zero on hand with live demand - the only loss no report shows',
      onHand: 'On hand', cover: 'Days of cover', soldMonth: 'Sold this month',
      coverHelp: 'Days of cover = on hand ÷ daily sales rate. Not selling is not zero - it is a different problem.',
      notSelling: 'not selling',
      trendTitle: 'Branch revenue by month',
      trendSub: 'last 12 months',
      transfersTitle: 'Transfer suggestions between the two warehouses',
      transfersSub: 'About to run out here, piled up there. The suggested quantity restores 60 days of cover here and never exceeds half of what the other branch holds - a transfer that creates the opposite stockout has solved nothing.',
      noTransfers: 'No worthwhile transfer right now - nothing is short here and surplus there',
      stockoutsTitle: 'Out of stock at this warehouse while still selling',
      stockoutsSub: 'ranked by the demand being missed',
      topTitle: 'Top sellers at this branch',
      tableTitle: 'Branch stock',
      here: 'On hand here', there: 'On hand there',
      coverHere: 'Cover here', coverThere: 'Cover there', move: 'Suggested move',
      moveHelp: 'Enough to restore 60 days of cover here, capped at half of the other branch stock',
      pageTitle: 'Warehouses', pageSub: 'What is free to use in each warehouse — a live snapshot, refreshed by the sync',
      skus: 'SKUs', value: 'Stock value', category: 'Category',
      free: 'Free to use', reservedWord: 'Reserved',
      allWarehouses: 'All warehouses', byWhTitle: 'Free to use by warehouse',
      stockTableTitle: 'Items in stock',
      pending: 'Warehouse stock has not been synced yet. Run the stock sync (odoosync branch-stock) and the numbers appear here.',
      within: 'Expiring within',
      expiryTitle: 'Product expiry',
      expirySub: 'Lot-tracked items in stock, soonest expiry first. Expiry lives on the lot in Odoo, so products not tracked by lot do not appear here.',
      expiryEmpty: 'No lot-tracked items under these filters — or the expiry sync (odoosync expiry) has not run yet.',
      expired: 'Expired',
      expSoon: 'Expiring within {n} days',
      expTracked: 'Total lot-tracked',
      earliest: 'Soonest expiry',
      info: {
        skus: [['Source', 'Odoo per-warehouse stock — stock.quant in internal locations'],
               ['Definition', 'Products holding a balance in the warehouse (or across all)'],
               ['Note', 'Excludes displays/stands and [DISC] like every other page; responds to the family/category/product filters']],
        free: [['Source', 'stock.quant — quantity minus reserved_quantity'],
               ['Definition', 'What is actually sellable. Reserved stock is committed to open orders and is not counted here'],
               ['Note', 'The number under the tile is total reserved under the same filters']],
        value: [['Source', 'Free quantity × standard cost (standard_price) from Odoo'],
                ['Definition', 'Value of free-to-use stock at cost, not at sale price']],
        expired: [['Source', 'stock.lot.expiration_date × on-hand for that lot from stock.quant'],
                  ['Definition', 'Units on lots whose expiry date is already past and are still in the warehouse'],
                  ['Note', 'Odoo stores the date as datetime; the sync slices it to a plain date']],
        expSoon: [['Definition', 'Units on lots expiring between today and the end of the chosen window (30/60/90/180 days)'],
                  ['Note', 'Excludes already-expired stock — that is the Expired tile']],
        expTracked: [['Definition', 'Total quantity across every dated lot under the filters, regardless of expiry date'],
                     ['Note', 'Expired + expiring-within-window + later = this total']]
      }
    },
    disc: {
      title: 'Discounts', sub: 'List price against realized price — where margin leaks',
      listPrice: 'List price', realized: 'Realized price', discount: 'Discount',
      leakage: 'Leakage', leakageHelp: 'Leakage = (list price − realized price) × units',
      topLeak: 'Biggest leakage', topProducts: 'Products leaking the most margin',
      byCustomer: 'By customer', bySalesperson: 'By salesperson',
      byGov: 'By governorate', byCategory: 'By category',
      invoiceLevel: 'Invoice-level discounts',
      invoiceLevelHelp: 'Discounts posted as their own invoice line, not against a product — excluded from product analysis',
      noList: 'No list price',
      noListHelp: 'Products with no list price have no computable discount — shown as “—”, never 0'
    },
    detail: {
      close: 'close', customers: 'Customers', cover: 'Cover', days: 'd',
      trend: 'Monthly trend', trendSub: 'Units per month, last 24 months of available data',
      topCustomers: 'Top customers', inPeriod: 'In the selected period',
      top15of: 'top 15 of', byGov: 'By governorate'
    },
    admin: {
      title: 'Administration', users: 'Users', roles: 'Roles', activity: 'Activity',
      newUser: 'New user', newRole: 'New role', username: 'Username',
      displayName: 'Display name', role: 'Role', scope: 'Scope', active: 'Active',
      lastSeen: 'Last seen', actions: 'Actions', save: 'Save', cancel: 'Cancel',
      del: 'Delete', password: 'Password', setPassword: 'Set password',
      pages: 'Pages', hiddenCols: 'Hidden columns', roleKey: 'Role key',
      nameAr: 'Arabic name', nameEn: 'English name',
      allReps: 'All salespersons', allGovs: 'All governorates',
      scopeHelp: 'Leave empty to let the user see everything',
      saved: 'Saved', confirmDelete: 'Delete — are you sure?',
      systemRole: 'system role', when: 'When', event: 'Event', page: 'Page',
      login: 'sign-in', pageview: 'page view',
      cols: { margin: 'Margin', cost: 'Cost', revenue: 'Revenue',
              stock_value: 'Stock value', customers: 'Customer names' },
      tables: 'Tables', hiddenTables: 'Hidden tables',
      tablesHelp: 'Hiding a table stops this role reading it anywhere in the dashboard',
      tableName: 'Supabase table', feeds: 'Feeds', provides: 'Provides',
      deniedPages: 'Denied pages',
      deniedHelp: 'Can only take away a page the role grants — never add one',
      risk: { blackout: 'blanks the dashboard', degrade: 'breaks pages', safe: 'limited effect' },
      confirmBlackout: 'This role will see no data at all. Are you sure?',
      noPageUse: 'no page reads this yet'
    },
    daysIdle: 'Days idle', stockValue: 'Stock value', cover: 'Cover (days)',
    velocity: 'Units/mo', suggested: 'Suggested qty', suggestedValue: 'Order value',
    bucket: 'Idle for', urgent: 'urgent', neverSold: 'never sold',
    st: {
      understock: 'reorder', dead: 'dead', dormant: 'dormant',
      overstock: 'overstock', healthy: 'healthy', inactive: 'inactive', oversold: 'oversold'
    },
    stHelp: {
      understock: 'Selling with under 30 days of cover — buy now',
      dead: 'In stock but no sale in 60 days — frozen capital',
      dormant: 'Idle, but its season has not arrived — wait, do not discount',
      overstock: 'More than 180 days of cover — stop buying',
      healthy: 'Cover between 30 and 180 days — no action',
      inactive: 'No stock and no sales — nothing to decide',
      oversold: 'Negative on-hand in Odoo — a bookkeeping error, not a stock decision'
    }
  }
};

export function lang() { return localStorage.getItem(LANG_KEY) || DEFAULT_LANG; }
export function T() { return t[lang()]; }

export function applyLang() {
  const l = lang();
  document.body.setAttribute('dir', l === 'ar' ? 'rtl' : 'ltr');
  document.body.setAttribute('lang', l);
  document.title = t[l].title;
  applyStaticTranslations();
}

/**
 * Fill every element carrying `data-t="pg.someKey"` from the language table.
 *
 * The card headings live in the HTML, not in JS, so before this they were
 * hardcoded English and simply did not change when the user pressed ع — the
 * page half-translated, which looks broken rather than bilingual. Keeping the
 * text in the same `t` object as everything else means one place to edit and
 * no second translation mechanism to forget about.
 *
 * A key with no translation is left exactly as authored in the HTML, so a
 * typo degrades to the English already on the page rather than blanking it.
 */
export function applyStaticTranslations(root = document) {
  const L = t[lang()];
  for (const el of root.querySelectorAll('[data-t]')) {
    const value = el.dataset.t.split('.').reduce((o, k) => (o == null ? o : o[k]), L);
    if (typeof value === 'string') el.textContent = value;
  }
}

function applyTheme() {
  const th = localStorage.getItem(THEME_KEY);
  if (th) document.documentElement.setAttribute('data-theme', th);
}

/** Renders an error so it can never be mistaken for "zero". */
export function showError(el, err) {
  const detail = err instanceof AuthError
    ? 'Session expired — sign in again.'
    : (err?.detail || err?.message || String(err));
  el.innerHTML =
    `<div class="state error"><strong>${esc(T().failed)}</strong>${esc(detail)}</div>`;
}

export function showLoading(el) {
  el.innerHTML = `<div class="state">${esc(T().loading)}</div>`;
}

export function showEmpty(el) {
  el.innerHTML = `<div class="state">${esc(T().nodata)}</div>`;
}

/**
 * The current user's permissions, from app_me(). Populated by requireAuth();
 * null before that, and null for an account with no app_users row.
 *
 * Read it for what to DRAW. It is not a security boundary — Postgres scopes
 * the rows and nulls the forbidden columns regardless of what this says.
 */
let _me = null;
export function me() { return _me; }

/** Convenience for the pages: may this user see this result field? */
export function showField(field) { return canField(_me, field); }

/** May this user read this Supabase table at all? */
export function showTable(key) { return tableVisible(_me, key); }
export function haveSales() { return hasSales(_me); }
export function haveStock() { return hasStock(_me); }

/**
 * Renders "this data is not available to your role" into an element.
 *
 * This exists because withheld data and missing data look identical once
 * rendered. The generic empty state ("no data for these filters") would send
 * a restricted user chasing a sync failure that never happened — the same
 * confusion the health strip was built to prevent.
 */
export function showUnavailable(el, which = null) {
  if (!el) return;
  const L = T();
  const msg = which === 'sales' ? L.unavailableSales
            : which === 'stock' ? L.unavailableStock
            : L.unavailable;
  el.innerHTML = `<div class="state"><span class="chip">🔒</span> ${esc(msg)}</div>`;
}

/** The banner shown at the top of a page whose data source is switched off. */
export function unavailableStrip() {
  if (!isProvisioned(_me)) return '';
  const L = T();
  const off = TABLES.filter(t => (_me.hidden_tables || []).includes(t.key));
  if (!off.length) return '';
  return `<div class="health">
    <span class="warn">🔒 ${esc(L.unavailable)}:</span>
    ${off.map(t => `<span><b>${esc(lang() === 'ar' ? t.ar : t.en)}</b></span>`).join('')}
  </div>`;
}

/** Renders a permissions dead end. Deliberately not an error and not "no data":
 *  those both suggest something is broken, and nothing here is. */
function showBlocked(title, help) {
  const app = document.getElementById('app');
  document.getElementById('shell')?.classList.add('hidden');
  app.classList.remove('hidden');
  app.innerHTML = `
    <div class="login-wrap"><div class="login card">
      <h2>${esc(title)}</h2>
      <p class="sub">${esc(help)}</p>
      <button class="btn" id="blocked-out">${esc(T().signout)}</button>
    </div></div>`;
  document.getElementById('blocked-out').onclick = () => { signOut(); location.reload(); };
}

/**
 * Gate the page behind a session AND a permission check. Resolves only once
 * signed in, provisioned, and allowed to open this page; renders the login
 * form, the not-provisioned notice, or redirects, otherwise.
 *
 * @param {string} [pageKey] which page this is. Defaults to the current URL,
 *        so the four existing pages needed no change to gain the guard.
 */
export function requireAuth(pageKey) {
  applyTheme();
  applyLang();

  return new Promise(resolve => {
    if (getSession()) return checkPermissions(pageKey, resolve);

    const app = document.getElementById('app');
    const L = T();
    document.getElementById('shell')?.classList.add('hidden');
    // The login form is rendered INTO #app, so #app must be visible. It starts
    // hidden to avoid a flash of empty layout; forgetting to unhide it here
    // renders the form inside display:none and shows a bare background.
    app.classList.remove('hidden');
    app.innerHTML = `
      <div class="login-wrap"><form class="login card" id="login-form">
        <h2>${esc(L.title)}</h2>
        <p class="sub">${esc(L.basis)}</p>
        <div class="field"><label for="u">${esc(L.user)}</label>
          <input id="u" autocomplete="username" required></div>
        <div class="field"><label for="p">${esc(L.pass)}</label>
          <input id="p" type="password" autocomplete="current-password" required></div>
        <button class="btn primary" type="submit">${esc(L.signin)}</button>
        <div class="err hidden" id="login-err"></div>
      </form></div>`;

    document.getElementById('login-form').addEventListener('submit', async e => {
      e.preventDefault();
      const err = document.getElementById('login-err');
      err.classList.add('hidden');
      try {
        await signIn(document.getElementById('u').value.trim(),
                     document.getElementById('p').value);
        location.reload();
      } catch (ex) {
        err.textContent = ex.message || 'Sign-in failed';
        err.classList.remove('hidden');
      }
    });
  });
}

/**
 * Load the caller's permissions and decide whether this page may open.
 *
 * The three outcomes are kept distinct on purpose. Rendering an empty
 * dashboard for any of them would look like a data outage, which is exactly
 * the confusion this project already refuses to create elsewhere:
 *
 *   no app_users row  → "your account is not set up yet"
 *   role has no pages → "your role has no pages assigned"
 *   wrong page        → silently redirect to one they do have
 */
async function checkPermissions(pageKey, resolve) {
  const L = T();
  let user;
  try {
    user = await appMe();
  } catch (err) {
    if (err instanceof AuthError) { signOut(); location.reload(); return; }
    // A network failure is NOT a permission failure. Fail closed, but say so
    // plainly rather than telling someone their account was removed.
    showBlocked(L.failed, err?.detail || err?.message || String(err));
    return;
  }

  _me = user;

  if (!isProvisioned(user)) {
    showBlocked(L.notProvisioned, L.notProvisionedHelp);
    return;
  }

  const allowed = visiblePages(user);
  if (!allowed.length) {
    showBlocked(L.notProvisioned, L.noPages);
    return;
  }

  const key = pageKey || pageKeyForHref(location.pathname);
  if (key && !allowed.some(p => p.key === key)) {
    const target = firstAllowedPage(user);
    // replace(), not assign(): the back button must not bounce them into the
    // forbidden page and straight back out again.
    if (target && pageKeyForHref(target) !== key) location.replace(target);
    else showBlocked(L.notProvisioned, L.noPages);
    return;
  }

  logActivity('page', key || 'unknown');   // fire and forget
  resolve();
}

/**
 * Top bar. Rendered on every page so the basis label is always visible.
 *
 * The nav is built from the user's role rather than from a fixed list, so a
 * role without Reorder simply has no Reorder link. Anyone who types the URL
 * anyway is bounced by the guard in requireAuth() — and even if they were not,
 * the page would render their own scoped, masked data.
 */
export function mountShell(active = '') {
  const L = T();
  const nav = visiblePages(_me).map(p => [p.href, L.nav[p.key] || p.key]);
  const scoped = isScoped(_me);

  document.getElementById('shell').innerHTML = `
    <div class="topbar">
      <span class="brand">Dabboos</span>
      ${nav.map(([href, label]) =>
        `<a class="btn${href === active ? ' primary' : ''}" href="${href}">${esc(label)}</a>`).join('')}
      <span class="basis" title="Numbers are invoice-based and will not match the sales dashboard">${esc(L.basis)}</span>
      ${scoped ? `<span class="basis warn" title="${esc(L.scopedNotice)}">◑ ${esc(L.scopedNotice)}</span>` : ''}
      ${_me ? `<span class="basis">${esc(_me.display_name || _me.username)}</span>` : ''}
      <button class="btn" id="lang-btn">${esc(L.lang)}</button>
      <button class="btn" id="cur-btn" title="${esc(L.curHint)}">${esc(activeCurrency().code)}</button>
      <button class="btn" id="theme-btn">◐</button>
      <button class="btn" id="out-btn">${esc(L.signout)}</button>
    </div>`;

  document.getElementById('lang-btn').onclick = () => {
    localStorage.setItem(LANG_KEY, lang() === 'ar' ? 'en' : 'ar');
    location.reload();
  };
  // IQD is the stored currency; USD is a fixed-rate view. Set the key only for
  // the USD view and clear it otherwise, so IQD stays the do-nothing default.
  document.getElementById('cur-btn').onclick = () => {
    if (activeCurrency().code === 'USD') localStorage.removeItem(CURRENCY_KEY);
    else localStorage.setItem(CURRENCY_KEY, 'USD');
    location.reload();
  };
  document.getElementById('theme-btn').onclick = () => {
    const cur = document.documentElement.getAttribute('data-theme');
    const next = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    localStorage.setItem(THEME_KEY, next);
  };
  document.getElementById('out-btn').onclick = () => { signOut(); location.reload(); };
}

/**
 * Data-health strip. Shown on every page so a blank chart is never mistaken
 * for zero sales — it says out loud what is and is not loaded.
 */
export function healthStrip(h) {
  const warn = [];
  if (Number(h.customers) === 0) warn.push('customers not synced — drill-downs show IDs');
  if (Number(h.stock_snapshots) === 0) warn.push('no stock history yet');
  return `<div class="health">
    <span><b>${esc(h.invoice_lines)}</b> invoice lines</span>
    <span><b>${esc(h.date_from)}</b> → <b>${esc(h.date_to)}</b></span>
    <span><b>${esc(h.products)}</b> products</span>
    <span>brand fill <b>${esc(h.brand_fill_pct)}%</b></span>
    ${warn.map(w => `<span class="warn">⚠ ${esc(w)}</span>`).join('')}
  </div>`;
}

/** Status chip: localised label + the reason in the tooltip. Never colour alone. */
export function statusChip(status) {
  const L = T();
  const cls = { dead: 'dead', dormant: 'dormant', understock: 'under',
                overstock: 'over', healthy: 'healthy', inactive: '',
                oversold: 'dead' }[status] || '';
  const label = L.st?.[status] || status;
  const help = L.stHelp?.[status] || '';
  return `<span class="chip ${cls}" title="${esc(help)}">${esc(label)}</span>`;
}

/** A legend explaining every status, so the table is self-explanatory. */
export function statusLegend() {
  const L = T();
  return `<div class="legend">
    <span class="legend-title">${esc(L.status)}:</span>
    ${Object.keys(L.st).filter(k => k !== 'dormant').map(k =>
      `<span>${statusChip(k)} ${esc(L.stHelp[k])}</span>`).join('')}
    <span class="legend-title">${esc(L.abcHelp)}</span>
  </div>`;
}

/**
 * Horizontal bars. Direct label per row; length carries magnitude.
 *
 * `total` turns on a share beside each value, and it is a DIFFERENT number
 * from the one the bar length uses. The bar is `value / max` — how this row
 * compares to the biggest row on screen. The share is `value / total` — how
 * this row compares to everything, including the rows that did not make the
 * list. A top-ten list shows ten of 1,431 products; computing the share from
 * the visible rows would make them sum to 100% and read a product at 3% of
 * revenue as 20%. So the caller passes the real total, and these percentages
 * deliberately do NOT sum to 100.
 *
 * Omitted (or zero, or masked to null) draws no share at all rather than
 * "0%", for the reason tile() gives: an absent share and a zero share mean
 * very different things and only one of them is honest.
 */
/**
 * A list of checkboxes, for choosing several of something.
 *
 * Replaces <select multiple>, which requires knowing that Ctrl-click adds to a
 * selection and Shift-click extends it. Most people do not, and the ones who
 * half-know it click a second option, silently lose the first, and then read a
 * number covering one category while believing it covers five. A checkbox
 * cannot fail that way: what is ticked is what is filtered, and the entire
 * state is visible at once rather than inferred from which rows look
 * highlighted.
 *
 * Lives in shell rather than insights because Overview builds its filter bar
 * by hand and imports only this module.
 */
export function checklist(id, options, selected = []) {
  const chosen = new Set(selected);
  const L = T();
  // The closed state is a summary that matches every other control on the row:
  // same height, same border, same caret. Open, the list floats over the page
  // rather than pushing it, so the filter bar keeps one line height whatever
  // is expanded. <details> supplies open/close with no script.
  const label = chosen.size === 0 ? '—'
              : chosen.size === 1 ? [...chosen][0]
              : `${chosen.size} ${L.selected}`;
  // Rendered, not maintained. Every filter change reloads the page, so this
  // count cannot drift out of step with the boxes -- there is no live state to
  // keep in sync and therefore no listener to forget.
  return `<details class="picker" id="${esc(id)}">` +
    `<summary title="${esc([...chosen].join(' · '))}"><span>${esc(label)}</span></summary>` +
    `<div class="picker-panel">${
      options.map(o => {
        const value = typeof o === 'string' ? o : o.value;
        const text = typeof o === 'string' ? o : (o.label ?? o.value);
        return `<label><input type="checkbox" value="${esc(value)}"${
          chosen.has(value) ? ' checked' : ''}><span>${esc(text)}</span></label>`;
      }).join('')}</div></details>`;
}

/** What is ticked, in the order the options were rendered. */
export function checklistValues(id) {
  const el = document.getElementById(id);
  if (!el) return [];
  return Array.from(el.querySelectorAll('input[type=checkbox]:checked')).map(i => i.value);
}

/**
 * The "where did this number come from" marker.
 *
 * Every figure here is a definition as much as a total -- net of returns,
 * excluding [DISC], stock valued at cost, idleness measured from the all-time
 * last sale. None of that is visible in "16.19B IQD", and the reconciliation
 * document that explains it is a separate page nobody has open while they are
 * looking at the tile. This puts the definition where the question gets asked.
 *
 * No JavaScript behind it: :hover serves the mouse and :focus-within serves
 * both the keyboard and a tap, because a <button> takes focus when touched. A
 * scripted tooltip would need dismissal, repositioning, and teardown on every
 * re-render, and would buy nothing over this.
 *
 * A <button> rather than a bare span so it is reachable by Tab and announced
 * as interactive; type="button" so it can never submit anything.
 */
export function infoIcon(text) {
  if (!text) return '';
  // A paragraph made the reader hunt. The first question anyone asks is which
  // Odoo document the figure comes from -- "sales orders or invoices?" -- and
  // in prose that answer sits somewhere in the middle of a sentence. Labelled
  // rows put it on the first line, where it is read rather than searched for.
  const body = Array.isArray(text)
    ? `<dl class="info-dl">${text.map(([term, detail]) =>
        `<dt>${esc(term)}</dt><dd>${esc(detail)}</dd>`).join('')}</dl>`
    : esc(text);
  return `<span class="info-wrap"><button type="button" class="info" ` +
         `aria-label="${esc(T().whereFrom)}">i</button>` +
         `<span class="info-pop" role="tooltip">${body}</span></span>`;
}

export function barList(rows, { colorVar = '--s1', total = null } = {}) {
  if (!rows.length) return `<div class="state">${esc(T().nodata)}</div>`;
  const max = Math.max(...rows.map(r => Math.abs(r.value)), 1);
  const denom = Number(total);
  const showShare = Number.isFinite(denom) && denom > 0;
  return `<div class="bars">${rows.map(r => `
    <div class="bar-row">
      <span class="bar-label" title="${esc(r.label)}">${esc(r.label)}</span>
      <span class="bar-value">${esc(r.display)}${
        showShare ? `<span class="bar-share">${esc(pct(Math.abs(r.value) / denom * 100))}</span>` : ''}</span>
      <span class="bar-track">
        <span class="bar-fill" style="width:${(Math.abs(r.value) / max * 100).toFixed(1)}%;background:var(${colorVar})"></span>
      </span>
    </div>`).join('')}</div>`;
}
