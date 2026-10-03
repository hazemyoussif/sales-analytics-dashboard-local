/* ============================================================
   Dabboos Sales Command Center — shared library
   i18n + formatting + API + sound + toast + navigation
   ============================================================ */
(function () {
  const CFG = window.DASH_CONFIG;

  // Disable Chart.js animations globally. On a live dashboard that re-renders
  // every poll, animations add CPU/GPU churn, make the page feel busy, and keep
  // the renderer from ever going idle (which breaks embedded previews and screen
  // capture). Charts still redraw instantly on data change. common.js always
  // loads AFTER chart.umd.min.js on the pages that use charts.
  if (window.Chart && window.Chart.defaults) {
    window.Chart.defaults.animation = false;
    window.Chart.defaults.animations = false;
  }

  /* ---------------- i18n ---------------- */
  const I18N = {
    ar: {
      brand: "مركز قيادة المبيعات",
      sub: "دبوس — لوحة حية",
      nav_overview: "النظرة العامة",
      nav_alerts: "مركز التنبيهات",
      nav_sales: "المندوبون (مقارنة أسبوعية)",
      nav_regions: "المدن والمحافظات",
      nav_collections: "التحصيل اليومي",
      nav_debt: "مديونية العملاء",
      lang_btn: "EN",
      live: "مباشر",
      updated: "آخر تحديث",
      odoo_synced: "آخر مزامنة من أودو",
      min_ago_tpl: "منذ {n} دقيقة",
      just_now: "الآن",
      next_sync: "التالية خلال",
      sync_checking: "جارٍ التحقق…",
      sync_delayed: "قد تكون المزامنة متأخرة — تحقّق من n8n",
      nav_products: "المنتجات",
      prod_title: "المنتجات والمخزون",
      prod_sub: "المجمّد في المخزن + الأكثر مبيعاً حسب العميل والمدينة",
      prod_kpi_stockval: "قيمة المخزون",
      prod_kpi_frozenval: "قيمة مجمّدة",
      prod_kpi_frozensku: "أصناف مجمّدة",
      prod_kpi_frozenpct: "% من قيمة المخزون",
      prod_kpi_top: "الأكثر مبيعاً (الشهر)",
      prod_frozen_title: "مخزون مجمّد (لم يُبع منذ فترة)",
      prod_hot_title: "الأكثر مبيعاً — حسب العميل والمدينة",
      prod_th_product: "المنتج",
      prod_th_category: "الفئة",
      prod_th_onhand: "المتوفر",
      prod_th_value: "القيمة",
      prod_th_lastsale: "آخر بيع",
      prod_th_idle: "أيام الركود",
      prod_th_velocity: "المعدّل (وحدة/شهر)",
      prod_th_units: "الكمية",
      prod_th_revenue: "الإيراد",
      prod_th_margin: "هامش الربح",
      prod_th_mix: "النسبة",
      prod_never_sold: "لم يُبع أبداً",
      prod_days: "يوم",
      prod_where_sells: "أين يُباع",
      prod_no_frozen: "لا يوجد مخزون مجمّد",
      prod_no_lines: "لا توجد بيانات مبيعات بعد",
      prod_top_customers: "أهم العملاء",
      prod_top_cities: "أهم المدن/المحافظات",
      prod_by_revenue: "حسب الإيراد",
      prod_by_units: "حسب الكمية",
      prod_threshold: "حدّ الركود",
      prod_all_reps: "كل المندوبين",
      prod_all_cities: "كل المحافظات",
      prod_all_cust: "كل العملاء",
      prod_search_cust: "بحث عن عميل…",
      prod_kpi_units_sold: "الكمية المباعة",
      prod_kpi_units_stock: "الكمية بالمخزون",
      prod_kpi_frozen_units: "قطعة مجمّدة",
      prod_warn_partial: "⚠️ بيانات المبيعات جزئية حالياً — قائمة «المجمّد» ستكون دقيقة بعد اكتمال تحميل الأشهر.",
      chk_frozen: "🔍 قارن في أودو: المخزون (المتوفر) + تحليل المبيعات حسب المنتج (آخر بيع)",
      chk_hot: "🔍 قارن في أودو: تحليل المبيعات حسب المنتج × العميل/المحافظة",
      src_products: "المنتجات",
      src_stock: "المخزون",
      src_lines: "بنود المبيعات",
      src_f_prod_catalog: "كتالوج المنتجات (الفئة/التكلفة)",
      src_f_frozen: "المخزون المجمّد",
      src_f_stockval: "قيمة المخزون",
      src_f_hot: "الأكثر مبيعاً حسب العميل/المدينة",
      src_f_lastsale: "آخر بيع لكل منتج",
      loading: "جارٍ التحميل…",
      error_load: "تعذّر تحميل البيانات من Supabase. تحقّق من الاتصال أو من إعدادات config.js.",
      // overview
      kpi_quotes: "عروض أسعار هذا الشهر",
      conversion: "نسبة التحويل",
      kpi_avg: "متوسط قيمة الطلب",
      kpi_value: "القيمة",
      orders: "طلب",
      ov_welcome: "مرحباً،",
      ov_sub: "ملخص عالي المستوى — استخدم البحث لتحديث كل البيانات",
      ov_confirmed: "الطلبات المؤكدة",
      ov_orders_day: "الطلبات لكل يوم",
      ov_not_confirmed: "ملغي",
      ov_quotes: "عروض أسعار",
      ov_total_incl: "الإجمالي كما في أودو",
      // overview v2
      // overview story headings — the question each row answers, in reading order
      sec_today: "١ · اليوم — كيف يسير يومنا؟",
      sec_month: "٢ · الشهر — هل نحن على المسار؟",
      sec_names: "٣ · الأسماء — بمن نتصل اليوم؟",
      sec_rhythm: "٤ · الإيقاع — إلى أين نتجه؟",
      sec_who: "٥ · النقد والعملاء — من يحمل أموالنا الآن؟",
      inv_today: "المفوتر اليوم (فواتير مرحّلة)",
      inv_today_tbl: "فواتير اليوم حسب الحالة",
      st_posted_tot: "مرحّلة (الإجمالي)",
      st_paid: "مدفوعة",
      st_partial: "مدفوعة جزئياً",
      st_unpaid: "غير مدفوعة",
      st_cancelled_inv: "ملغاة",
      invoices_w: "فاتورة",
      col_count: "العدد",
      col_still_unpaid: "المتبقي",
      collected_same_day: "حُصّل في نفس اليوم",
      inv_gap_note: "طلبات مؤكدة اليوم لم تُفوتر بعد",
      inv_by_rep: "فواتير اليوم حسب المندوب",
      inv_by_rep_month: "فواتير الشهر حسب المندوب",
      collected_so_far: "حُصّل حتى الآن",
      pay_today_tbl: "مدفوعات اليوم حسب الحالة",
      pay_by_rep: "مدفوعات اليوم حسب المندوب",
      pay_by_rep_month: "مدفوعات الشهر حسب المندوب",
      pay_total: "الإجمالي",
      pay_paid: "مستلَم",
      pay_transit: "قيد التحويل",
      pay_rejected: "مرفوضة",
      pay_cancelled: "ملغاة",
      pay_excluded_note: "غير محسوبة في المحصّل",
      pay_cash_basis: "المحصّل = مستلَم + قيد التحويل",
      pay_grand_total: "الإجمالي شاملاً المرفوضة والملغاة",
      col_notdue: "غير مستحق بعد",
      col_total_open: "إجمالي الذمة",
      cust_detail: "كشف العميل — الفواتير المفتوحة",
      col_invoice: "الفاتورة",
      col_inv_date: "تاريخ الفاتورة",
      col_due_date: "الاستحقاق",
      chk_partner: "للمطابقة مع أودو: افتح صف العميل في «أعمار الذمم» (سهم التوسيع) أو «دفتر الشريك» — نفس الأسطر والمبالغ وتواريخ الاستحقاق.",
      basis_orders: "أساس: الطلبات",
      basis_invoices: "أساس: الفواتير",
      region_basis_inv: "الأساس: فواتير العملاء المرحّلة حسب تاريخ الفاتورة، بقيمها شاملة الضريبة. «فواتير المبيعات» و«المرتجعات» (إشعارات الدائن) بندان منفصلان — لا يُخلطان. «الصافي» = المبيعات − المرتجعات = وهو ما يطابق شاشة أودو «الفواتير» المجمّعة حسب الولاية. المحافظة = حقل «الولاية» في بطاقة العميل كما هو.",
      col_sales_inv: "فواتير المبيعات",
      col_returns: "المرتجعات",
      col_net: "الصافي (المبيعات − المرتجعات)",
      rg_money_title: "أين المال؟ — المبيعات حسب المحافظة",
      rg_movers_title: "من يصعد ومن يتراجع؟",
      rg_movers_sub: "التغيّر مقابل الفترة السابقة",
      rg_push_title: "أين نركّز؟ — تغطية العملاء",
      rg_push_sub: "عملاء اشتروا هذه الفترة ÷ إجمالي العملاء في المحافظة",
      rg_total_sales: "إجمالي المبيعات — هذه الفترة",
      rg_vs_prev: "مقابل الفترة السابقة",
      rg_active_regions: "محافظات نشطة",
      rg_active_cities: "مدن نشطة",
      rg_rising: "الأعلى صعوداً",
      rg_falling: "الأعلى تراجعاً",
      rg_new: "جديدة",
      rg_no_prev: "لا توجد بيانات فترة سابقة للمقارنة بعد",
      rg_to_chase: "للمتابعة",
      rg_quiet: "توقّفوا",
      rg_buyers_of: "مشترون من",
      rg_delta_hd: "التغيّر",
      rg_quiet_title: "عملاء توقّفوا عن الشراء",
      rg_quiet_modal_sub: "عملاء اشتروا في الفترة السابقة ولم يشتروا في هذه الفترة — مرتّبون حسب قيمة مشترياتهم السابقة.",
      rg_col_customer: "العميل",
      rg_col_rep: "المندوب",
      rg_col_lastorder: "آخر طلب",
      chk_aged: "للمطابقة مع أودو: المحاسبة ← التقارير ← أعمار الذمم — «المتأخر» = مجموع أعمدة التأخير (1-30…الأقدم)، «غير مستحق بعد» = عمود At Date، «إجمالي الذمة» = عمود الإجمالي.",
      chk_inv_today: "للمطابقة مع أودو: المحاسبة ← فواتير العملاء — تصفية «تاريخ الفاتورة = اليوم» والتجميع حسب حالة الدفع.",
      chk_pay: "للمطابقة مع أودو: المحاسبة ← مدفوعات العملاء — التجميع حسب الحالة (المبالغ بإشارتها: الاسترجاع بالسالب).",
      refresh_btn: "تحديث كل الأرقام من قاعدة البيانات",
      ord_by_day: "الطلبات حسب اليوم",
      col_day: "اليوم",
      chk_orders: "للمطابقة مع أودو: المبيعات ← الطلبات — التجميع حسب «تاريخ الطلب: يوم» ثم الحالة (القيمة = مجموع كل الحالات كما في عمود الإجمالي).",
      chk_inv_month: "للمطابقة مع أودو: المحاسبة ← فواتير العملاء — تصفية «تاريخ الفاتورة = هذا الشهر» (مرحّلة فقط) والتجميع حسب المندوب.",
      chk_pay_month: "للمطابقة مع أودو: المحاسبة ← مدفوعات العملاء — تصفية «تاريخ الدفع = هذا الشهر» والتجميع حسب المندوب.",
      col_collected: "المحصّل",
      due_7d: "يستحق خلال ٧ أيام",
      ov_vs_typical: "عن معدل نفس اليوم (٤ أسابيع)",
      ov_stuck: "أقدم من ٣ أيام",
      ov_today_orders: "طلبات اليوم (كما في أودو)",
      ov_confirmed_short: "مؤكد",
      ex_vs_lmtd: "مقارنة بنفس الأيام من الشهر الماضي",
      dso_title: "أعمار الذمم (فواتير مفتوحة)",
      dso_le30: "≤٣٠ يوم",
      dso_gt60: ">٦٠ يوم",
      od_days: "أيام التأخير",
      credit_exposure: "الانكشاف الائتماني الكلي",
      cancel_rate: "نسبة الإلغاء",
      conc10: "حصة أكبر ١٠ عملاء",
      of_period_rev: "من إيراد الفترة",
      wk_rev_title: "الإيراد الأسبوعي المؤكد (آخر ٦ أسابيع)",
      wk_partial: "أسبوع جارٍ",
      transit_title: "نقد بالطريق — من يحمله الآن؟",
      col_holder: "الحامل (دفتر اليومية)",
      col_oldest: "أقدم دفعة",
      col_risky: "طلبات حرجة",
      col_transit: "بالطريق",
      days_word: "يوم",
      as_of_snapshot: "حسب آخر لقطة",
      ov_top_govs: "أعلى المحافظات (قيمة)",
      ov_customers: "عدد العملاء",
      ov_status_mix: "توزيع حالات الطلبات",
      no_alerts: "لا توجد تنبيهات حالياً ✅",
      // overview: today strip + action tables
      ov_today_sales: "مبيعات اليوم (مؤكدة)",
      ov_pending_cash: "نقد قيد التحصيل (بذمة المندوبين)",
      ov_cancelled: "طلبات ملغاة هذا الشهر",
      ov_orders_month: "طلبات مؤكدة هذا الشهر",
      ov_top_debtors: "أكبر المتأخرين — عملاء للمتابعة اليوم",
      ov_leaderboard: "المندوبون — مبيعات مقابل تحصيل (هذا الشهر)",
      col_collected: "المُحصَّل",
      col_sales: "المبيعات",
      payments_count: "دفعة",
      // executive summary band (merged into the overview)
      exec_title: "النظرة التنفيذية",
      ex_revenue: "المفوتر — هذا الشهر (فواتير مرحّلة)",
      ex_rev_collected: "حُصّل منها",
      ex_target: "الهدف",
      ex_of_target: "من الهدف",
      ex_pace: "على المسار لتحقيق",
      ex_cash: "النقد المُحصّل — هذا الشهر",
      ex_dso: "متوسط أيام التحصيل",
      ex_overdue: "المتأخرات المستحقة",
      ex_conc_sub: "حصة أعلى ١٠ عملاء",
      ex_top_rep: "أفضل مندوب",
      ex_top_gov: "أعلى محافظة",
      ex_var: "قيمة معرّضة للخطر",
      ex_var_sub: "تنبيهات حرجة",
      ex_story: "القصة في سطر",
      ex_proj: "المتوقّع بنهاية الشهر",
      // alerts
      alerts_title: "مركز التنبيهات",
      alerts_sub: "طلبات تحتاج مراجعة بشرية — مرتبة حسب الخطورة",
      filter_all: "الكل",
      filter_critical: "حرجة",
      filter_warning: "تحذيرات",
      col_order: "الطلب",
      col_customer: "العميل",
      col_rep: "المندوب",
      col_city: "المدينة",
      col_amount: "القيمة",
      col_reasons: "أسباب المراجعة",
      critical: "حرج",
      warning: "تحذير",
      // sales
      sales_title: "أداء المندوبين",
      sales_sub: "المبيعات المؤكدة لكل مندوب — أسبوعي وشهري",
      last_week: "الأسبوع الماضي",
      wow: "أسبوعي",
      mom: "شهري",
      sp_week: "هذا الأسبوع",
      sp_month: "هذا الشهر",
      sp_reps: "المندوبون النشطون",
      top_customers: "أكبر العملاء — آخر 30 يوم (مؤكد)",
      new_risk: "مخاطر جديدة (هذا الشهر)",
      uninvoiced: "مؤكد بلا فاتورة",
      no_data: "لا توجد بيانات بعد",
      orders_count: "عدد الطلبات",
      // regions
      regions_title: "المدن والمحافظات",
      regions_sub: "الطلبات المؤكدة حسب المحافظة ثم المدينة",
      region_basis: "الأساس: الطلبات المؤكدة (أوامر بيع/منجزة) بقيمها شاملة الضريبة حسب تاريخ الطلب. المحافظة = حقل «الولاية» في بطاقة العميل بأودو كما هو تماماً، والمدينة = حقل «المدينة» كما هو — «بدون» = الحقل فارغ في أودو. 🔍 للمطابقة: المبيعات ← الطلبات — تصفية «تاريخ الطلب» + الحالة، ثم تصفية «العميل ← الولاية»، أو Pivot تحليل المبيعات (صفوف: الولاية ← الحالة، مقياس «الإجمالي» — تنبيه: عدّاده يحسب أسطر المنتجات لا الطلبات).",
      unmapped: "مدن غير مصنّفة",
      unmapped_note: "طلبات لم نستطع ربط مدينتها بمحافظة (اسم المدينة غير معروف في القاموس). راجع أسماء المدن في أودو أو أضِفها للقاموس.",
      nocity: "بدون مدينة",
      nocity_note: "طلبات لا تحتوي على مدينة أصلاً في أودو — يجب تعبئة حقل «المدينة» في ملف العميل داخل أودو حتى تُحتسب ضمن محافظتها.",
      gov_none: "بدون (None)",
      gov_none_note: "عملاء حقل «الولاية» فارغ في بطاقتهم بأودو — نفس صف None في أودو تماماً. املأ الحقل وسينتقلون لمحافظتهم هنا وهناك معاً.",
      govs_title: "المحافظات",
      cities_title: "المدن",
      gov_all: "كل المحافظات",
      cities_count: "عدد المدن",
      region: "المدينة",
      share: "الحصة",
      // daily collections page (تحصيل)
      coll_title: "تحصيل المندوبين — يومي",
      coll_sub: "المبالغ المُحصَّلة لكل مندوب لكل يوم",
      coll_today: "محصّل اليوم",
      coll_pending: "قيد التحصيل",
      coll_total: "الإجمالي",
      coll_grid: "التحصيل لكل مندوب — آخر ١٤ يوم",
      coll_grand_total: "إجمالي التحصيل",
      coll_14d: "تحصيل آخر ١٤ يوم",
      coll_period: "تحصيل الفترة المحددة",
      coll_mtd: "الشهر حتى الآن",
      coll_last_month: "الشهر الماضي",
      coll_mom: "التغير الشهري",
      coll_sales_month: "مبيعات الفترة",
      coll_vs_sales: "التحصيل ÷ المفوتر",
      coll_rep_perf: "أداء المندوبين في التحصيل",
      // customer debt by salesperson (مديونية العملاء)
      debt_title: "مديونية العملاء المستحقة",
      debt_customers_no: "عدد العملاء المستحقين",
      debt_total_all: "إجمالي المديونية",
      debt_due_all: "إجمالي المستحق",
      debt_due_pct: "نسبة المستحق من المديونية",
      debt_due_sub: "المتأخّر عن السداد",
      debt_due_pct_sub: "المستحق ÷ الإجمالي",
      col_debit: "المديونية",
      col_overdue: "المتأخّر",
      col_gov: "المحافظة",
      debt_by_gov: "المتأخرات حسب المحافظة",
      debt_by_rep: "المتأخرات حسب المندوب",
      debt_concentration: "تركّز المديونية",
      debt_top10_sub: "حصة أعلى ١٠ عملاء من إجمالي المتأخرات",
      debt_page_sub: "أرصدة العملاء المستحقة الحالية — حسب المندوب",
      debt_table_title: "العملاء المدينون — تفصيل",
      debt_note_live: "المديونية رصيد لحظي (الوضع الآن)، لذا لا ينطبق فلتر التاريخ عليها.",
      // shared filter bar
      f_from: "من تاريخ",
      f_to: "إلى تاريخ",
      f_rep_all: "كل المندوبين",
      f_customer_ph: "بحث بالعميل…",
      f_clear: "مسح",
      f_results: "نتيجة",
      // order modal
      order_details: "تفاصيل الطلب",
      customer_profile: "ملف العميل المالي",
      risk_assessment: "تقييم المخاطر",
      no_risk: "لا توجد مخاطر على هذا الطلب ✅",
      f_state: "الحالة", f_type: "النوع", f_date: "تاريخ الطلب",
      f_total: "الإجمالي",
      f_qty: "الكمية", f_products: "عدد المنتجات", f_invoices: "الفواتير",
      f_credit: "الرصيد الدائن", f_credit_limit: "حد الائتمان", f_balance: "الرصيد",
      f_overdue: "المتأخرات", f_avg3m: "متوسط 3 أشهر", f_pay6m: "متوسط المدفوعات 6 أشهر",
      f_curmonth: "مبيعات الشهر", f_dso: "أيام التحصيل", f_trust: "الثقة",
      f_rank: "تصنيف العميل", f_ontime: "الالتزام بالموعد", f_invoiced: "إجمالي الفوترة",
      f_payment: "طريقة الدفع", f_best: "الأكثر مبيعاً",
      // acknowledgments
      mark_reviewed: "تمّت المراجعة ✓",
      add_note: "إضافة ملاحظة (اختياري)…",
      reviewed_ok: "تم تسجيل المراجعة",
      ack_total: "إجمالي التنبيهات",
      ack_seen: "تمت مراجعتها",
      ack_ignored: "لم يراجعها أحد",
      ack_rate: "نسبة المراجعة",
      ack_reviews: "مرات المراجعة",
      ack_notes: "الملاحظات",
      ack_status: "الحالة",
      st_seen: "تمت المراجعة",
      st_ignored: "بانتظار المراجعة",
      no_notes: "لا توجد ملاحظات",
      filter_ignored: "غير مُراجَعة",
      filter_seen: "مُراجَعة",
      not_found: "لم يتم العثور على الطلب",
      search_ph: "بحث: طلب، عميل، مندوب، مدينة…",
      export_pdf: "تصدير PDF",
      sound_on: "الصوت مفعّل", sound_off: "الصوت متوقف",
      // auth + admin panel
      nav_admin: "لوحة التحكم",
      logout: "تسجيل الخروج",
      login_title: "تسجيل الدخول",
      login_sub: "أدخل اسم المستخدم وكلمة المرور للمتابعة",
      login_user: "اسم المستخدم",
      login_pass: "كلمة المرور",
      login_btn: "دخول",
      login_wait: "جارٍ الدخول…",
      login_err: "اسم المستخدم أو كلمة المرور غير صحيحة",
      login_inactive: "الحساب غير مفعّل — راجع مسؤول النظام",
      login_noprofile: "لا يوجد ملف لهذا المستخدم — راجع مسؤول النظام",
      admin_title: "لوحة التحكم",
      admin_sub: "إدارة المستخدمين والصلاحيات ومتابعة حركة الاستخدام",
      admin_users: "المستخدمون",
      admin_traffic: "حركة الاستخدام",
      admin_create: "إضافة مستخدم جديد",
      admin_create_btn: "إنشاء المستخدم",
      admin_created: "تم إنشاء المستخدم وتفعيله ✓",
      admin_saved: "تم حفظ التغييرات ✓",
      admin_save: "حفظ",
      admin_active: "مفعّل",
      admin_suspended: "موقوف",
      admin_role: "الدور",
      role_admin: "مسؤول",
      role_management: "إدارة",
      role_alerts: "تنبيهات فقط",
      admin_pages: "الصفحات المسموح بها",
      admin_scope: "المندوبون المرتبطون",
      admin_scope_all: "كل المندوبين",
      admin_scope_reps: "مندوب",
      admin_scope_none: "لا يوجد مندوبون",
      admin_setpw: "كلمة المرور",
      admin_pw_ph: "كلمة مرور جديدة",
      admin_pw_set: "تعيين",
      admin_pw_done: "تم تحديث كلمة المرور",
      admin_pw_short: "كلمة المرور قصيرة (٦ أحرف على الأقل)",
      scope_viewing: "تعرض أرقام المندوبين:",
      admin_user_col: "المستخدم",
      admin_fullname: "الاسم الكامل",
      admin_password: "كلمة المرور (٦ أحرف على الأقل)",
      admin_username_ph: "اسم المستخدم (إنجليزي بدون مسافات)",
      admin_err: "فشلت العملية — حاول مرة أخرى",
      admin_user_exists: "اسم المستخدم مستخدم مسبقاً",
      admin_you: "هذا حسابك",
      admin_pw_note: "لإعادة تعيين كلمة مرور مستخدم: من لوحة Supabase → Authentication → Users، أو أوقف الحساب وأنشئ حساباً جديداً.",
      admin_sources: "مصادر البيانات (إظهار / إخفاء)",
      admin_sources_sub: "أخفِ اللوحات والرسوم التي تعتمد على جدول معيّن من Supabase — يُطبَّق على جميع المستخدمين.",
      src_col_table: "الجدول",
      src_col_feeds: "يظهر في لوحة القيادة",
      src_col_visible: "ظاهر",
      src_hidden_note: "عند الإخفاء تختفي كل اللوحات المرتبطة بهذا الجدول من كل الصفحات.",
      src_invoices: "الفواتير",
      src_payments: "المدفوعات",
      src_orders: "الطلبات",
      src_customers: "العملاء",
      src_f_inv_today: "المفوتر اليوم + فواتير اليوم حسب الحالة/المندوب",
      src_f_inv_month: "فواتير الشهر حسب المندوب",
      src_f_debt: "صفحة الديون + أقدم المدينين + أعمار الذمم",
      src_f_cash: "التحصيل اليوم/الشهر",
      src_f_collections: "صفحة التحصيلات",
      src_f_pay_tables: "جداول مدفوعات اليوم/الشهر حسب الحالة والمندوب",
      src_f_orders_today: "طلبات اليوم",
      src_f_charts: "رسوم الطلبات اليومية/الأسبوعية + أفضل العملاء",
      src_f_regions: "صفحة المناطق",
      src_f_sales: "صفحة المندوبين",
      src_f_names: "أسماء العملاء والمندوبين",
      src_f_geo: "المحافظة/المدينة على الخرائط والجداول",
      tr_views_today: "زيارات اليوم",
      tr_views_7: "زيارات آخر ٧ أيام",
      tr_users_7: "مستخدمون نشطون (٧ أيام)",
      tr_per_day: "الزيارات حسب اليوم (آخر ٣٠ يوماً)",
      tr_by_page: "حسب الصفحة (٧ أيام)",
      tr_by_user: "حسب المستخدم (٧ أيام)",
      tr_recent: "آخر النشاطات",
      tr_page: "الصفحة",
      tr_views: "الزيارات",
      tr_when: "الوقت",
      tr_empty: "لا توجد بيانات بعد",
      states: { draft: "عرض سعر", sent: "مُرسل", sale: "طلب مؤكد", done: "مكتمل", cancel: "ملغي" },
      trust: { good: "جيد", normal: "عادي", bad: "سيء" }
    },
    en: {
      brand: "Sales Command Center",
      sub: "Dabboos — Live",
      nav_overview: "Overview",
      nav_alerts: "Alert Center",
      nav_sales: "Salespeople (WoW)",
      nav_regions: "Cities & Governorates",
      nav_collections: "Daily Collections",
      nav_debt: "Customer Debt",
      lang_btn: "ع",
      live: "LIVE",
      updated: "Updated",
      odoo_synced: "Synced from Odoo",
      min_ago_tpl: "{n} min ago",
      just_now: "just now",
      next_sync: "next in",
      sync_checking: "checking…",
      sync_delayed: "Sync may be delayed — check n8n",
      nav_products: "Products",
      prod_title: "Products & Warehouse",
      prod_sub: "Frozen stock + top sellers by customer & city",
      prod_kpi_stockval: "Stock value",
      prod_kpi_frozenval: "Frozen value",
      prod_kpi_frozensku: "Frozen SKUs",
      prod_kpi_frozenpct: "% of stock value",
      prod_kpi_top: "Top seller (month)",
      prod_frozen_title: "Frozen stock (not sold recently)",
      prod_hot_title: "Top sellers — by customer & city",
      prod_th_product: "Product",
      prod_th_category: "Category",
      prod_th_onhand: "On hand",
      prod_th_value: "Value",
      prod_th_lastsale: "Last sale",
      prod_th_idle: "Days idle",
      prod_th_velocity: "Rate (units/mo)",
      prod_th_units: "Units",
      prod_th_revenue: "Revenue",
      prod_th_margin: "Margin",
      prod_th_mix: "Mix %",
      prod_never_sold: "never sold",
      prod_days: "d",
      prod_where_sells: "Where it sells",
      prod_no_frozen: "No frozen stock",
      prod_no_lines: "No sales data yet",
      prod_top_customers: "Top customers",
      prod_top_cities: "Top cities / governorates",
      prod_by_revenue: "By revenue",
      prod_by_units: "By units",
      prod_threshold: "Idle threshold",
      prod_all_reps: "All reps",
      prod_all_cities: "All governorates",
      prod_all_cust: "All customers",
      prod_search_cust: "Search customer…",
      prod_kpi_units_sold: "Units sold",
      prod_kpi_units_stock: "Units in stock",
      prod_kpi_frozen_units: "frozen units",
      prod_warn_partial: "⚠️ Sales data is partial right now — the Frozen list becomes accurate once all months finish loading.",
      chk_frozen: "🔍 Check in Odoo: Inventory > Products (on-hand) + Sales Analysis by Product (last sale)",
      chk_hot: "🔍 Check in Odoo: Sales Analysis by Product × Customer/State",
      src_products: "Products",
      src_stock: "Stock",
      src_lines: "Order lines",
      src_f_prod_catalog: "Product catalog (category/cost)",
      src_f_frozen: "Frozen stock",
      src_f_stockval: "Stock value",
      src_f_hot: "Top sellers by customer/city",
      src_f_lastsale: "Last sale per product",
      loading: "Loading…",
      error_load: "Could not load data from Supabase. Check your connection or config.js.",
      kpi_quotes: "Quotations this month",
      conversion: "Conversion",
      kpi_avg: "Avg order value",
      kpi_value: "Value",
      orders: "orders",
      ov_welcome: "Welcome,",
      ov_sub: "High-level summary — use search to update all data",
      ov_confirmed: "Confirmed orders",
      ov_orders_day: "Orders per day",
      ov_not_confirmed: "Cancelled",
      ov_quotes: "Quotations",
      ov_total_incl: "Total (as in Odoo)",
      // overview v2
      // overview story headings — the question each row answers, in reading order
      sec_today: "1 · Today — how is the day going?",
      sec_month: "2 · The month — are we on track?",
      sec_names: "3 · Names — who do we call today?",
      sec_rhythm: "4 · Rhythm — which way are we trending?",
      sec_who: "5 · Cash & customers — who holds our money right now?",
      inv_today: "Invoiced today (posted)",
      inv_today_tbl: "Today's invoices by status",
      st_posted_tot: "Posted (total)",
      st_paid: "Paid",
      st_partial: "Partially paid",
      st_unpaid: "Not paid",
      st_cancelled_inv: "Cancelled",
      invoices_w: "invoices",
      col_count: "Count",
      col_still_unpaid: "Still unpaid",
      collected_same_day: "collected same day",
      inv_gap_note: "confirmed today, not yet invoiced",
      inv_by_rep: "Today's invoices by salesperson",
      inv_by_rep_month: "This month's invoices by salesperson",
      collected_so_far: "collected so far",
      pay_today_tbl: "Today's payments by status",
      pay_by_rep: "Today's payments by salesperson",
      pay_by_rep_month: "This month's payments by salesperson",
      pay_total: "Total",
      pay_paid: "Received",
      pay_transit: "In transit",
      pay_rejected: "Rejected",
      pay_cancelled: "Cancelled",
      pay_excluded_note: "not counted as cash",
      pay_cash_basis: "Collected = received + in transit",
      pay_grand_total: "Total incl. rejected & cancelled",
      col_notdue: "Not due yet",
      col_total_open: "Total open",
      cust_detail: "Customer detail — open invoices",
      col_invoice: "Invoice",
      col_inv_date: "Invoice date",
      col_due_date: "Due date",
      chk_partner: "Verify in Odoo: expand the customer's row in Aged Receivable (the arrow) or open their Partner Ledger — same lines, amounts, and due dates.",
      basis_orders: "Basis: Orders",
      basis_invoices: "Basis: Invoices",
      region_basis_inv: "Basis: posted customer invoices by invoice date, tax-inclusive. \"Sales invoices\" and \"Returns\" (credit notes) are SEPARATE line items — not blended. \"Net\" = Sales − Returns = what Odoo's Invoices screen grouped by State shows. Governorate = the customer's State field verbatim.",
      col_sales_inv: "Sales invoices",
      col_returns: "Returns",
      col_net: "Net (Sales − Returns)",
      rg_money_title: "Where the money is — sales by governorate",
      rg_movers_title: "Who's growing, who's slipping",
      rg_movers_sub: "Change vs the previous period",
      rg_push_title: "Where to push — customer coverage",
      rg_push_sub: "Customers who bought this period ÷ all customers in the region",
      rg_total_sales: "Total sales — this period",
      rg_vs_prev: "vs previous period",
      rg_active_regions: "Active regions",
      rg_active_cities: "Active cities",
      rg_rising: "Top riser",
      rg_falling: "Top faller",
      rg_new: "new",
      rg_no_prev: "No previous-period data to compare yet",
      rg_to_chase: "to chase",
      rg_quiet: "went quiet",
      rg_buyers_of: "bought, of",
      rg_delta_hd: "Change",
      rg_quiet_title: "Customers who went quiet",
      rg_quiet_modal_sub: "Bought last period and nothing this period — sorted by how much they were buying.",
      rg_col_customer: "Customer",
      rg_col_rep: "Rep",
      rg_col_lastorder: "Last order",
      chk_aged: "Verify in Odoo: Accounting → Reporting → Aged Receivable — Overdue = the late columns (1-30…Older), Not due yet = the At Date column, Total open = the Total column.",
      chk_inv_today: "Verify in Odoo: Accounting → Customer Invoices — filter Invoice Date = today, group by Payment Status.",
      chk_pay: "Verify in Odoo: Accounting → Customer Payments — group by Status (signed amounts: refunds negative).",
      refresh_btn: "Refresh all numbers from the database",
      ord_by_day: "Orders by day",
      col_day: "Day",
      chk_orders: "Verify in Odoo: Sales → Orders — group by Order Date: Day, then Status (money = all statuses, like Odoo's Total column).",
      chk_inv_month: "Verify in Odoo: Accounting → Customer Invoices — filter Invoice Date = this month (posted only), group by Salesperson.",
      chk_pay_month: "Verify in Odoo: Accounting → Customer Payments — filter Payment Date = this month, group by Salesperson.",
      col_collected: "Collected",
      due_7d: "Due within 7 days",
      ov_vs_typical: "vs 4-week same-weekday avg",
      ov_stuck: "older than 3 days",
      ov_today_orders: "Orders today (as in Odoo)",
      ov_confirmed_short: "confirmed",
      ex_vs_lmtd: "vs same days last month",
      dso_title: "Receivables age (open invoices)",
      dso_le30: "≤30d",
      dso_gt60: ">60d",
      od_days: "Days overdue",
      credit_exposure: "Total credit exposure",
      cancel_rate: "Cancel rate",
      conc10: "Top-10 customer share",
      of_period_rev: "of period revenue",
      wk_rev_title: "Weekly confirmed revenue (last 6 weeks)",
      wk_partial: "current week",
      transit_title: "Cash in transit — who holds it now?",
      col_holder: "Holder (journal)",
      col_oldest: "Oldest payment",
      col_risky: "Critical orders",
      col_transit: "In transit",
      days_word: "days",
      as_of_snapshot: "as of latest snapshot",
      ov_top_govs: "Top governorates (value)",
      ov_customers: "Customers",
      ov_status_mix: "Order status mix",
      no_alerts: "No alerts right now ✅",
      // overview: today strip + action tables
      ov_today_sales: "Sales today (confirmed)",
      ov_pending_cash: "Cash in process (held by reps)",
      ov_cancelled: "Cancelled this month",
      ov_orders_month: "Confirmed orders this month",
      ov_top_debtors: "Top overdue customers — follow up today",
      ov_leaderboard: "Reps — sales vs collected (this month)",
      col_collected: "Collected",
      col_sales: "Sales",
      payments_count: "payments",
      // executive summary band (merged into the overview)
      exec_title: "Executive summary",
      ex_revenue: "Invoiced — this month (posted)",
      ex_rev_collected: "collected so far",
      ex_target: "Target",
      ex_of_target: "of target",
      ex_pace: "On pace for",
      ex_cash: "Cash collected — this month",
      ex_dso: "DSO (days)",
      ex_overdue: "Outstanding overdue",
      ex_conc_sub: "Top 10 customers' share",
      ex_top_rep: "Top rep",
      ex_top_gov: "Top governorate",
      ex_var: "Value at risk",
      ex_var_sub: "critical alerts",
      ex_story: "The story in one line",
      ex_proj: "Projected month-end",
      alerts_title: "Alert Center",
      alerts_sub: "Orders needing human review — sorted by severity",
      filter_all: "All",
      filter_critical: "Critical",
      filter_warning: "Warnings",
      col_order: "Order",
      col_customer: "Customer",
      col_rep: "Rep",
      col_city: "City",
      col_amount: "Amount",
      col_reasons: "Review reasons",
      critical: "Critical",
      warning: "Warning",
      sales_title: "Salesperson performance",
      sales_sub: "Confirmed sales per rep — weekly & monthly",
      last_week: "Last week",
      wow: "WoW",
      mom: "MoM",
      sp_week: "This week",
      sp_month: "This month",
      sp_reps: "Active reps",
      top_customers: "Top customers — last 30 days (confirmed)",
      new_risk: "New risk (this month)",
      uninvoiced: "Confirmed, not invoiced",
      no_data: "No data yet",
      orders_count: "Orders",
      regions_title: "Cities & Governorates",
      regions_sub: "Confirmed orders by governorate, then city",
      region_basis: "Basis: confirmed orders (Sales Order/Done), tax-inclusive totals, by order date. Governorate = the customer's State field in Odoo VERBATIM; city = the City field verbatim — \"None\" = the field is empty in Odoo. 🔍 Verify: Sales → Orders filtered by Order Date + Status + Customer→State, or the Sales Analysis pivot (rows State→Status, Total measure — its Count counts product LINES, not orders).",
      unmapped: "Unmapped cities",
      unmapped_note: "Orders whose city could not be matched to a governorate (city name not in the dictionary). Review the city names in Odoo or add them to the dictionary.",
      nocity: "No city recorded",
      nocity_note: "Orders with no city at all in Odoo — fill the customer's City field in Odoo so they count under their governorate.",
      gov_none: "None",
      gov_none_note: "Customers whose State field is empty on the Odoo customer form — exactly Odoo's None row. Fill the field and they move into their governorate on both screens at once.",
      govs_title: "Governorates",
      cities_title: "Cities",
      gov_all: "All governorates",
      cities_count: "Cities",
      region: "City",
      share: "Share",
      // daily collections page
      coll_title: "Salesperson collections — daily",
      coll_sub: "Money collected per salesperson, per day",
      coll_today: "Collected today",
      coll_pending: "Pending",
      coll_total: "Total",
      coll_grid: "Collection per rep — last 14 days",
      coll_grand_total: "Total collected",
      coll_14d: "Last 14 days collected",
      coll_period: "Selected period collected",
      coll_mtd: "Month-to-date",
      coll_last_month: "Last month",
      coll_mom: "MoM change",
      coll_sales_month: "Period sales",
      coll_vs_sales: "Collected ÷ invoiced",
      coll_rep_perf: "Rep collection performance",
      // customer debt by salesperson
      debt_title: "Outstanding customer debt",
      debt_customers_no: "Customers due",
      debt_total_all: "Total receivable",
      debt_due_all: "Total due",
      debt_due_pct: "Due ratio",
      debt_due_sub: "Overdue",
      debt_due_pct_sub: "Due ÷ total",
      col_debit: "Receivable",
      col_overdue: "Overdue",
      col_gov: "Governorate",
      debt_by_gov: "Overdue by governorate",
      debt_by_rep: "Overdue by salesperson",
      debt_concentration: "Debt concentration",
      debt_top10_sub: "Top 10 customers' share of total overdue",
      debt_page_sub: "Current outstanding customer balances — by salesperson",
      debt_table_title: "Debtor customers — detail",
      debt_note_live: "Debt is a live balance (as of now), so the date filter does not apply to it.",
      // shared filter bar
      f_from: "From",
      f_to: "To",
      f_rep_all: "All reps",
      f_customer_ph: "Search customer…",
      f_clear: "Clear",
      f_results: "results",
      order_details: "Order details",
      customer_profile: "Customer financial profile",
      risk_assessment: "Risk assessment",
      no_risk: "No risks on this order ✅",
      f_state: "State", f_type: "Type", f_date: "Order date",
      f_total: "Total",
      f_qty: "Quantity", f_products: "Products", f_invoices: "Invoices",
      f_credit: "Credit", f_credit_limit: "Credit limit", f_balance: "Balance",
      f_overdue: "Overdue", f_avg3m: "3-month avg", f_pay6m: "6-month avg payments",
      f_curmonth: "Month sales", f_dso: "DSO (days)", f_trust: "Trust",
      f_rank: "Customer rank", f_ontime: "On-time rate", f_invoiced: "Total invoiced",
      f_payment: "Payment method", f_best: "Best sellers",
      // acknowledgments
      mark_reviewed: "Mark reviewed ✓",
      add_note: "Add a note (optional)…",
      reviewed_ok: "Review recorded",
      ack_total: "Total alerts",
      ack_seen: "Reviewed",
      ack_ignored: "Not reviewed by anyone",
      ack_rate: "Review rate",
      ack_reviews: "Reviews",
      ack_notes: "Notes",
      ack_status: "Status",
      st_seen: "Reviewed",
      st_ignored: "Awaiting review",
      no_notes: "No notes",
      filter_ignored: "Not reviewed",
      filter_seen: "Reviewed",
      not_found: "Order not found",
      search_ph: "Search: order, customer, rep, city…",
      export_pdf: "Export PDF",
      sound_on: "Sound on", sound_off: "Sound off",
      // auth + admin panel
      nav_admin: "Admin Panel",
      logout: "Log out",
      login_title: "Sign in",
      login_sub: "Enter your username and password to continue",
      login_user: "Username",
      login_pass: "Password",
      login_btn: "Sign in",
      login_wait: "Signing in…",
      login_err: "Wrong username or password",
      login_inactive: "This account is not active — contact the administrator",
      login_noprofile: "No profile for this user — contact the administrator",
      admin_title: "Admin Panel",
      admin_sub: "Manage users, permissions and usage traffic",
      admin_users: "Users",
      admin_traffic: "Traffic",
      admin_create: "Add a new user",
      admin_create_btn: "Create user",
      admin_created: "User created and activated ✓",
      admin_saved: "Changes saved ✓",
      admin_save: "Save",
      admin_active: "Active",
      admin_suspended: "Suspended",
      admin_role: "Role",
      role_admin: "Admin",
      role_management: "Management",
      role_alerts: "Alerts only",
      admin_pages: "Allowed pages",
      admin_scope: "Attached salespersons",
      admin_scope_all: "Full access",
      admin_scope_reps: "reps",
      admin_scope_none: "No salespersons found",
      admin_setpw: "Password",
      admin_pw_ph: "New password",
      admin_pw_set: "Set",
      admin_pw_done: "Password updated",
      admin_pw_short: "Password too short (min 6)",
      scope_viewing: "Viewing numbers for:",
      admin_user_col: "User",
      admin_fullname: "Full name",
      admin_password: "Password (min 6 characters)",
      admin_username_ph: "username (english, no spaces)",
      admin_err: "Operation failed — try again",
      admin_user_exists: "Username already taken",
      admin_you: "This is your account",
      admin_pw_note: "To reset a user's password: Supabase dashboard → Authentication → Users, or suspend the account and create a new one.",
      admin_sources: "Data sources (show / hide)",
      admin_sources_sub: "Hide the panels and charts fed by a specific Supabase table — applies to every user.",
      src_col_table: "Table",
      src_col_feeds: "Shows up on the dashboard as",
      src_col_visible: "Visible",
      src_hidden_note: "Hiding a table removes every panel tied to it, on all pages.",
      src_invoices: "Invoices",
      src_payments: "Payments",
      src_orders: "Orders",
      src_customers: "Customers",
      src_f_inv_today: "Invoiced-today KPI + today's invoices by status / salesperson",
      src_f_inv_month: "This month's invoices by salesperson",
      src_f_debt: "Debt page + top debtors + receivables aging",
      src_f_cash: "Cash collected today / this month",
      src_f_collections: "Collections page",
      src_f_pay_tables: "Today's / month payment tables by status & salesperson",
      src_f_orders_today: "Today's orders count",
      src_f_charts: "Daily / weekly order charts + top customers",
      src_f_regions: "Regions page",
      src_f_sales: "Salespeople page",
      src_f_names: "Customer & rep names",
      src_f_geo: "Governorate / city on maps & tables",
      tr_views_today: "Views today",
      tr_views_7: "Views last 7 days",
      tr_users_7: "Active users (7 days)",
      tr_per_day: "Views per day (last 30 days)",
      tr_by_page: "By page (7 days)",
      tr_by_user: "By user (7 days)",
      tr_recent: "Recent activity",
      tr_page: "Page",
      tr_views: "Views",
      tr_when: "When",
      tr_empty: "No data yet",
      states: { draft: "Quotation", sent: "Sent", sale: "Confirmed", done: "Done", cancel: "Cancelled" },
      trust: { good: "Good", normal: "Normal", bad: "Bad" }
    }
  };

  let LANG = localStorage.getItem("dash_lang") || CFG.DEFAULT_LANG || "ar";
  const t = (k) => I18N[LANG][k] !== undefined ? I18N[LANG][k] : k;
  const isAR = () => LANG === "ar";

  /* ---------------- security: HTML escaping ----------------
     Every value that originates in the database (customer/rep/city names,
     order names, alert notes, risk reasons) is user-controlled free text and
     MUST be escaped before it is placed into innerHTML. The alert "note" field
     in particular is written anonymously via ackAlert(), so an unescaped render
     is a stored-XSS hole. Use D.esc() around ANY DB string in a template. */
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  /* ---------------- formatting ---------------- */
  function fmtNum(n) {
    if (n === null || n === undefined || n === false || isNaN(n)) return "—";
    return Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 });
  }
  function fmtMoney(n) {
    const cur = isAR() ? CFG.CURRENCY_AR : CFG.CURRENCY;
    if (n === null || n === undefined || n === false || isNaN(n)) return "—";
    // compact for large numbers
    const abs = Math.abs(Number(n));
    let s;
    if (abs >= 1e6) s = (n / 1e6).toLocaleString("en-US", { maximumFractionDigits: 2 }) + "M";
    else if (abs >= 1e3) s = (n / 1e3).toLocaleString("en-US", { maximumFractionDigits: 1 }) + "K";
    else s = Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 });
    return s + " " + cur;
  }
  function fmtMoneyFull(n) {
    const cur = isAR() ? CFG.CURRENCY_AR : CFG.CURRENCY;
    if (n === null || n === undefined || n === false || isNaN(n)) return "—";
    return Number(n).toLocaleString("en-US", { maximumFractionDigits: 0 }) + " " + cur;
  }
  // Convert a stored UTC datetime ("2026-07-01 20:11:19") to its Asia/Baghdad
  // calendar day "YYYY-MM-DD". Odoo stores datetimes in UTC but displays and
  // groups them in the user's timezone — bucketing by Baghdad day keeps the
  // dashboard's daily numbers aligned with what Odoo screens show.
  function bagDay(s) {
    if (!s) return "";
    const str = String(s);
    const d = new Date(str.includes("T") ? str : str.replace(" ", "T") + "Z");
    if (isNaN(d)) return str.slice(0, 10);
    return d.toLocaleDateString("en-CA", { timeZone: "Asia/Baghdad" });
  }
  // Pure date-string arithmetic on "YYYY-MM-DD" (no timezone surprises).
  function addDays(dstr, n) {
    const d = new Date(dstr + "T00:00:00Z");
    d.setUTCDate(d.getUTCDate() + n);
    return d.toISOString().slice(0, 10);
  }
  // Saturday-start week (Iraq convention) for a "YYYY-MM-DD" day.
  function weekStartSat(dstr) {
    const d = new Date(dstr + "T00:00:00Z");
    return addDays(dstr, -((d.getUTCDay() + 1) % 7));
  }
  function fmtDate(s) {
    if (!s) return "—";
    const d = new Date(String(s).replace(" ", "T"));
    if (isNaN(d)) return s;
    return d.toLocaleDateString(isAR() ? "ar-EG" : "en-GB", { year: "numeric", month: "short", day: "numeric" });
  }
  function fmtTime(s) {
    const d = s ? new Date(s) : new Date();
    return d.toLocaleTimeString(isAR() ? "ar-EG" : "en-GB", { hour: "2-digit", minute: "2-digit" });
  }

  /* ---------------- API (reads Supabase REST directly) ----------------
     Every request carries the logged-in user's JWT (auth.js) so Row-Level
     Security in Supabase decides what the caller may see. The anon key by
     itself reads nothing once supabase/auth-setup.sql has been applied. */
  async function authHeaders(extra) {
    const A = window.DASH_AUTH;
    if (A) { await A.ensureToken(); return A.headers(extra); }
    return Object.assign(
      { apikey: CFG.SUPABASE_ANON_KEY, Authorization: "Bearer " + CFG.SUPABASE_ANON_KEY },
      extra || {});
  }
  function authFail(res) {
    // 401 = the JWT is expired/revoked → back to the login page.
    if (res.status === 401 && window.DASH_AUTH) { window.DASH_AUTH.signOut(); return true; }
    return false;
  }

  async function sbGet(pathAndQuery) {
    const base = CFG.SUPABASE_URL.replace(/\/$/, "");
    const res = await fetch(base + "/rest/v1/" + pathAndQuery, { headers: await authHeaders() });
    if (!res.ok) { authFail(res); throw new Error("Supabase HTTP " + res.status); }
    return res.json();
  }

  // Generic authorized write (used by the admin panel: PATCH dash_users …).
  async function sbWrite(method, pathAndQuery, body) {
    const base = CFG.SUPABASE_URL.replace(/\/$/, "");
    const res = await fetch(base + "/rest/v1/" + pathAndQuery, {
      method: method,
      headers: await authHeaders({ "Content-Type": "application/json", Prefer: "return=representation" }),
      body: JSON.stringify(body)
    });
    if (!res.ok) { authFail(res); throw new Error("Supabase HTTP " + res.status); }
    return res.status === 204 ? null : res.json();
  }

  // Freshness — the real moment n8n last pulled from Odoo. Every upsert stamps
  // updated_at, so max(updated_at) across the three 20-min pipelines (orders,
  // payments, invoices) is the true "data as of" time. dashboard_customers is a
  // 2-hour master sync — excluded so it never makes the sales numbers look
  // stale. Errors/RLS-blocked tables count as 0 (we use whatever the caller can
  // read). Cached 60s so the header poll is nearly free.
  let _syncCache = { at: 0, val: null };
  async function loadLastSync(force) {
    if (!force && Date.now() - _syncCache.at < 60000) return _syncCache.val;
    const tables = ["dashboard_orders", "dashboard_payments", "dashboard_invoices"];
    const times = await Promise.all(tables.map(async tbl => {
      try {
        const r = await sbGet(`${tbl}?select=updated_at&order=updated_at.desc&limit=1`);
        return (r && r[0] && r[0].updated_at) ? new Date(r[0].updated_at).getTime() : 0;
      } catch (e) { return 0; }
    }));
    const max = Math.max(0, ...times);
    _syncCache = { at: Date.now(), val: max > 0 ? new Date(max).toISOString() : null };
    return _syncCache.val;
  }

  /* ---------------- data-source visibility (admin-controlled, GLOBAL) ----------------
     An admin can hide whole panels that are fed by a specific raw table.
     The setting lives in dash_settings.hidden_sources (Supabase, RLS: admins
     write / everyone reads — see supabase/data-source-visibility.sql). Any
     element tagged data-src="dashboard_invoices" (space-separate for several)
     is hidden when its source is in the hidden set. Panels are static wrappers
     in each page's HTML, so one pass hides them regardless of inner re-renders.

     DATA_SOURCES also documents WHAT each table feeds — used by the admin
     reference view AND as the toggle labels. `feeds` are i18n keys. */
  const DATA_SOURCES = [
    { table: "dashboard_invoices",  key: "src_invoices",  feeds: ["src_f_inv_today", "src_f_inv_month", "src_f_debt"] },
    { table: "dashboard_payments",  key: "src_payments",  feeds: ["src_f_cash", "src_f_collections", "src_f_pay_tables"] },
    { table: "dashboard_orders",    key: "src_orders",    feeds: ["src_f_orders_today", "src_f_charts", "src_f_regions", "src_f_sales"] },
    { table: "dashboard_customers", key: "src_customers", feeds: ["src_f_names", "src_f_geo"] }
  ];
  const HIDDEN_SRC_LKEY = "dash_hidden_src";
  let _hiddenSrc = null; // cached Set of hidden table names

  function hiddenSrcLocal() {
    try { return new Set(JSON.parse(localStorage.getItem(HIDDEN_SRC_LKEY) || "[]")); }
    catch (e) { return new Set(); }
  }
  // Read the global setting. Falls back to the last-known local copy (then
  // empty) if the table is missing or the network fails — so a not-yet-run
  // migration or an offline poll never blanks the whole dashboard.
  async function loadHiddenSources(force) {
    if (_hiddenSrc && !force) return _hiddenSrc;
    try {
      const rows = await sbGet("dash_settings?select=value&key=eq.hidden_sources");
      const arr = (rows && rows[0] && rows[0].value && rows[0].value.tables) || [];
      _hiddenSrc = new Set(arr);
      localStorage.setItem(HIDDEN_SRC_LKEY, JSON.stringify(arr));
    } catch (e) { _hiddenSrc = hiddenSrcLocal(); }
    return _hiddenSrc;
  }
  // Admin only (RLS enforces it). The 'hidden_sources' row is seeded by the
  // SQL, so a PATCH always hits an existing row — no upsert needed.
  async function setHiddenSources(arr) {
    await sbWrite("PATCH", "dash_settings?key=eq.hidden_sources",
      { value: { tables: arr }, updated_at: new Date().toISOString() });
    _hiddenSrc = new Set(arr);
    localStorage.setItem(HIDDEN_SRC_LKEY, JSON.stringify(arr));
  }
  function applyHiddenTo(root, hiddenSet) {
    (root || document).querySelectorAll("[data-src]").forEach(el => {
      const hide = el.getAttribute("data-src").split(/\s+/).filter(Boolean).some(s => hiddenSet.has(s));
      el.style.display = hide ? "none" : "";
    });
  }
  // Synchronous re-apply from the cached/local set — no network. Pages call
  // this at the end of every render so dynamically-rebuilt tiles (KPI cards,
  // exec cards, minis) get hidden again after each poll.
  function applyHidden(root) {
    applyHiddenTo(root, _hiddenSrc || hiddenSrcLocal());
  }
  // Paint instantly from the last-known local copy (no flash on repeat loads),
  // then reconcile with the server copy. Called once per page from buildChrome.
  function applyDataSourceVisibility() {
    applyHiddenTo(document, hiddenSrcLocal());
    loadHiddenSources(true).then(set => applyHiddenTo(document, set)).catch(() => {});
  }

  /* ---------------- raw-table adapters ----------------
     These used to be n8n-computed snapshots. They are now built in the
     browser from the raw tables, in the SAME return shapes, so the pages
     that consume them did not change. Raw tables are the single source of
     truth — every number here can be traced to rows you can inspect. */

  const bagToday = () => bagDay(new Date().toISOString());

  // 14-day per-rep collections grid (paid vs in_process), from dashboard_payments.
  async function buildRepCollections() {
    const today = bagToday();
    const from = addDays(today, -13);
    const rows = dedupeBy(await sbGetAll(
      `dashboard_payments?select=payment_id,date,amount,state,salesperson,user_id&date=gte.${from}&state=neq.canceled&order=date.desc,payment_id.desc`), "payment_id");
    const days = [];
    for (let i = 13; i >= 0; i--) days.push(addDays(today, -i));
    const reps = new Map();
    const totals = {};
    days.forEach(d => { totals[d] = { paid: 0, pending: 0, total: 0 }; });
    let grandPaid = 0, grandPending = 0;
    for (const p of rows) {
      const day = String(p.date).slice(0, 10);
      if (!totals[day]) continue;
      const amt = Number(p.amount) || 0;
      const paid = p.state === "paid" ? amt : 0;
      const pend = p.state === "in_process" ? amt : 0;
      if (!paid && !pend) continue; // ignore draft/other states
      const key = p.user_id != null ? p.user_id : (p.salesperson || "—");
      if (!reps.has(key)) reps.set(key, {
        user_id: p.user_id != null ? p.user_id : null, salesperson: p.salesperson || "—",
        paid_total: 0, pending_total: 0, total: 0, count: 0,
        daily: Object.fromEntries(days.map(d => [d, { paid: 0, pending: 0, total: 0, count: 0 }]))
      });
      const r = reps.get(key);
      r.paid_total += paid; r.pending_total += pend; r.total += paid + pend; r.count++;
      const cell = r.daily[day];
      cell.paid += paid; cell.pending += pend; cell.total += paid + pend; cell.count++;
      totals[day].paid += paid; totals[day].pending += pend; totals[day].total += paid + pend;
      grandPaid += paid; grandPending += pend;
    }
    const repList = [...reps.values()]
      .map(r => ({ ...r, today: r.daily[today] || { paid: 0, pending: 0, total: 0, count: 0 } }))
      .sort((a, b) => (b.today.total - a.today.total) || (b.total - a.total));
    return { generated_at: new Date().toISOString(), currency: CFG.CURRENCY, today, days,
      reps: repList, totals_by_day: totals, grand_paid: grandPaid, grand_pending: grandPending,
      grand_total: grandPaid + grandPending };
  }

  /* -------- debt from TRANSACTIONAL facts: open invoices --------
     receivable = Σ unpaid residuals of posted invoices; overdue = the slice
     whose due_date has passed. Every figure traces to invoice rows you can
     open in Odoo. The customers master only supplies IDENTITY (name,
     assigned rep, governorate) — its precomputed money fields are unused. */
  async function loadOpenInvoices() {
    // residual != 0, not > 0: unapplied credits (customer payments / credit
    // notes not yet matched to invoices) carry NEGATIVE residuals and must
    // subtract, or every customer's debt reads too high. This mirrors
    // Odoo's Aged Receivable, which nets both signs per bucket.
    return dedupeBy(await sbGetAll(
      `dashboard_invoices?select=invoice_id,partner_id,partner_name,user_id,salesperson,amount_residual,due_date` +
      `&state=eq.posted&amount_residual=neq.0&order=invoice_id.desc`), "invoice_id");
  }
  async function loadCustomerIdentity() {
    const rows = await sbGetAll(
      `dashboard_customers?select=partner_id,complete_name,city,governorate,user_id,salesperson&order=partner_id.desc`);
    const m = new Map();
    rows.forEach(c => m.set(c.partner_id, c));
    return m;
  }
  function debtorsFromInvoices(inv, idmap, today) {
    const cust = new Map();
    for (const i of inv) {
      const pid = i.partner_id != null ? i.partner_id : "?" + (i.partner_name || "");
      if (!cust.has(pid)) {
        const c = idmap.get(i.partner_id) || {};
        cust.set(pid, {
          partner_id: i.partner_id != null ? i.partner_id : null,
          name: c.complete_name || i.partner_name || "—",
          city: c.governorate || c.city || "",
          user_id: c.user_id != null ? c.user_id : (i.user_id != null ? i.user_id : null),
          // assigned rep from the customer master first (debt is attributed
          // to the account owner); the invoice's own salesperson as fallback
          salesperson: c.salesperson || i.salesperson || null,
          receivable: 0, overdue: 0, oldestLate: 0
        });
      }
      const e = cust.get(pid);
      // a customer's FIRST open line can be a payment/credit (no salesperson
      // on those) — let any later line with a rep fill the blanks, or a
      // customer with named invoice lines shows as Unassigned
      if (e.salesperson == null && i.salesperson) e.salesperson = i.salesperson;
      if (e.user_id == null && i.user_id != null) e.user_id = i.user_id;
      const amt = Number(i.amount_residual) || 0;
      e.receivable += amt;
      const due = i.due_date ? String(i.due_date).slice(0, 10) : "";
      if (due && due < today) {
        e.overdue += amt; // credits net against the overdue slice too
        if (amt > 0) {    // "days late" only makes sense for actual debits
          const late = Math.round((Date.parse(today) - Date.parse(due)) / 864e5);
          if (late > e.oldestLate) e.oldestLate = late;
        }
      }
    }
    return cust;
  }

  async function buildRepDebt() {
    const today = bagToday();
    const [inv, idmap] = await Promise.all([loadOpenInvoices(), loadCustomerIdentity()]);
    const cust = debtorsFromInvoices(inv, idmap, today);
    const reps = new Map();
    for (const c of cust.values()) {
      const key = c.user_id != null ? c.user_id : (c.salesperson || "—");
      if (!reps.has(key)) reps.set(key, {
        user_id: c.user_id != null ? c.user_id : null,
        salesperson: c.salesperson || "— غير محدد / Unassigned",
        customers: [], receivable_total: 0, overdue_total: 0
      });
      const r = reps.get(key);
      r.customers.push({ partner_id: c.partner_id != null ? c.partner_id : null,
        name: c.name, city: c.city, receivable: c.receivable, overdue: c.overdue });
      r.receivable_total += c.receivable; r.overdue_total += c.overdue;
    }
    const repList = [...reps.values()]
      .map(r => ({ ...r, customer_count: r.customers.length,
        customers: r.customers.sort((a, b) => b.receivable - a.receivable) }))
      .sort((a, b) => b.receivable_total - a.receivable_total);
    return { generated_at: new Date().toISOString(), currency: CFG.CURRENCY, reps: repList,
      grand_receivable: repList.reduce((s, r) => s + r.receivable_total, 0),
      grand_overdue: repList.reduce((s, r) => s + r.overdue_total, 0),
      customers_total: repList.reduce((s, r) => s + r.customer_count, 0) };
  }

  // Receivables health, all from OPEN INVOICES: true aging by due date
  // (amounts, not counts), total exposure = the open book, top overdue with
  // days-late. New-risk stays orders-based. See docs/METRICS.md.
  // ("Confirmed, not invoiced" was removed from the UI by request 2026-07-12.)
  async function buildCollections() {
    const today = bagToday();
    const monthStart = today.slice(0, 7) + "-01";
    const [inv, idmap, riskRaw] = await Promise.all([
      loadOpenInvoices(),
      loadCustomerIdentity(),
      sbGetAll(`${CFG.TABLES.orders}?select=order_id,amount_total&state=in.(sale,done)&level=eq.critical&date_order=gte.${monthStart}&order=order_id.desc`)
    ]);
    const risk = dedupeBy(riskRaw, "order_id");
    const num2 = n => Number(n) || 0;

    // aging buckets in IQD: le30 = not yet due or ≤30 days late,
    // 31–60 late, >60 late, unknown = no due date on the invoice
    const dso_buckets = { le30: 0, b31_60: 0, gt60: 0, unknown: 0 };
    const due7End = addDays(today, 7);
    let overdue_total = 0, exposure = 0, due_7d = 0;
    inv.forEach(i => {
      const amt = num2(i.amount_residual);
      exposure += amt;
      const due = i.due_date ? String(i.due_date).slice(0, 10) : "";
      if (!due) { dso_buckets.unknown += amt; return; }
      const late = Math.round((Date.parse(today) - Date.parse(due)) / 864e5);
      if (late > 0) overdue_total += amt;
      // the collections calendar: money coming due in the next 7 days —
      // what reps should chase BEFORE it becomes overdue
      if (late <= 0 && due < due7End) due_7d += amt;
      if (late > 60) dso_buckets.gt60 += amt;
      else if (late > 30) dso_buckets.b31_60 += amt;
      else dso_buckets.le30 += amt;
    });
    const cust = debtorsFromInvoices(inv, idmap, today);
    const overdue_customers = [...cust.values()].filter(c => c.overdue > 0)
      .map(c => ({ name: c.name, overdue: c.overdue, dso: c.oldestLate }))
      .sort((a, b) => b.overdue - a.overdue).slice(0, 8);

    const sumV = a => a.reduce((s, o) => s + num2(o.amount_total), 0);
    return {
      generated_at: new Date().toISOString(), currency: CFG.CURRENCY,
      customers_evaluated: cust.size,
      overdue_total: overdue_total,
      credit_exposure: exposure,
      due_7d: due_7d,
      dso_buckets, overdue_customers,
      new_risk_value: sumV(risk), new_risk_count: risk.length
    };
  }

  // Fallback names for invoice rows synced before the `salesperson` column
  // existed (pre n8n v5.6 / before the backfill): resolve the invoice's
  // user_id → rep name via the customer master's assigned rep.
  async function loadRepNames() {
    const rows = await sbGetAll(
      `dashboard_customers?select=user_id,salesperson&user_id=not.is.null&order=partner_id.desc`);
    const m = new Map();
    rows.forEach(r => {
      if (r.user_id != null && r.salesperson && !m.has(r.user_id)) m.set(r.user_id, r.salesperson);
    });
    return m;
  }

  // Today's customer invoices (INV/ documents dated today), classified the
  // way Odoo's badges do: cancelled (state) · paid (residual 0) · partially
  // paid (0 < residual < total) · not paid (residual = total). Also returns
  // how much of today's invoicing was ALREADY collected today, and the
  // posted book broken down per salesperson.
  async function buildInvoicesToday() {
    const today = bagToday();
    const [rowsRaw, repNames] = await Promise.all([
      sbGetAll(
        `dashboard_invoices?select=invoice_id,name,user_id,salesperson,partner_name,amount_total,amount_residual,state` +
        `&invoice_date=eq.${today}&name=like.INV*&order=invoice_id.desc`),
      cachedApi("rep_names", loadRepNames)
    ]);
    const rows = dedupeBy(rowsRaw, "invoice_id");
    const num2 = n => Number(n) || 0;
    const repName = x => x.salesperson || repNames.get(x.user_id) ||
      (x.user_id != null ? "ID " + x.user_id : "— غير محدد / Unassigned");
    const bucket = () => ({ n: 0, value: 0, residual: 0 });
    const out = { posted: bucket(), paid: bucket(), partial: bucket(), unpaid: bucket(), cancelled: bucket() };
    const reps = new Map();
    const postedRows = []; // invoice-level rows so pages can filter by rep AND customer
    const cancelledRows = []; // same, for the cancelled status row
    let collected = 0;
    for (const x of rows) {
      const t = num2(x.amount_total), res = num2(x.amount_residual);
      const add = b => { b.n++; b.value += t; b.residual += res; };
      if (x.state === "cancel") {
        add(out.cancelled);
        cancelledRows.push({ user_id: x.user_id != null ? x.user_id : null,
          salesperson: repName(x), partner_name: x.partner_name || "", value: t, residual: res });
        continue;
      }
      if (x.state !== "posted") continue; // drafts don't count anywhere
      add(out.posted);
      collected += t - res;
      if (res === 0) add(out.paid);
      else if (res < t) add(out.partial);
      else add(out.unpaid);
      postedRows.push({ user_id: x.user_id != null ? x.user_id : null,
        salesperson: repName(x), partner_name: x.partner_name || "", value: t, residual: res });
      const rk = x.user_id != null ? x.user_id : (x.salesperson || "—");
      if (!reps.has(rk)) reps.set(rk, {
        user_id: x.user_id != null ? x.user_id : null,
        // the invoice's own name snapshot wins; customer-master fallback
        // covers rows synced before the column existed
        salesperson: repName(x),
        n: 0, value: 0, residual: 0
      });
      add(reps.get(rk));
    }
    return { generated_at: new Date().toISOString(), currency: CFG.CURRENCY, today,
      posted: out.posted, paid: out.paid, partial: out.partial,
      unpaid: out.unpaid, cancelled: out.cancelled, collected_today: collected,
      posted_rows: postedRows, cancelled_rows: cancelledRows,
      by_rep: [...reps.values()].sort((a, b) => b.value - a.value) };
  }

  // The adapters aggregate thousands of rows — recomputing them on every
  // 60-second poll multiplied the page's requests. Receivables/debt data
  // changes hourly at most, so cache the results for a few minutes; the
  // live numbers (orders/payments windows) still refresh every poll.
  const apiCache = {};
  const API_CACHE_MS = 4 * 60 * 1000;
  async function cachedApi(key, build) {
    const c = apiCache[key];
    if (c && Date.now() - c.at < API_CACHE_MS) return c.data;
    const data = await build();
    apiCache[key] = { at: Date.now(), data: data };
    return data;
  }

  // Invoiced revenue for the month band: posted INV/ invoices of this month,
  // plus last month's SAME-DAYS total for an honest MoM. Requires the
  // "BACKFILL Months" run once in n8n v5.5 — before it, fully-paid invoices
  // from before the ledger cutover are missing and the totals undercount.
  async function buildInvoicesMonth() {
    const today = bagToday();
    const thisMonth = today.slice(0, 7);
    const domN = Number(today.slice(8, 10));
    const lastMonthStart = addDays(thisMonth + "-01", -1).slice(0, 7) + "-01";
    const lastMonth = lastMonthStart.slice(0, 7);
    const [rowsRaw, repNames] = await Promise.all([
      sbGetAll(
        `dashboard_invoices?select=invoice_id,user_id,salesperson,partner_name,amount_total,amount_residual,state,invoice_date` +
        `&invoice_date=gte.${lastMonthStart}&name=like.INV*&state=eq.posted&order=invoice_id.desc`),
      cachedApi("rep_names", loadRepNames)
    ]);
    const rows = dedupeBy(rowsRaw, "invoice_id");
    const num2 = n => Number(n) || 0;
    const repName = x => x.salesperson || repNames.get(x.user_id) ||
      (x.user_id != null ? "ID " + x.user_id : "— غير محدد / Unassigned");
    const reps = new Map();
    const postedRows = []; // invoice-level, so pages can filter by rep AND customer
    let value = 0, count = 0, collected = 0, lastMTD = 0, lastAny = 0;
    for (const x of rows) {
      const d = String(x.invoice_date).slice(0, 10);
      const t = num2(x.amount_total);
      if (d.slice(0, 7) === thisMonth) {
        value += t; count++;
        const res = num2(x.amount_residual);
        collected += t - res;
        postedRows.push({ user_id: x.user_id != null ? x.user_id : null,
          salesperson: repName(x), partner_name: x.partner_name || "", value: t, residual: res });
        // per-rep slice of the month's posted book (same keying as today's)
        const rk = x.user_id != null ? x.user_id : (x.salesperson || "—");
        if (!reps.has(rk)) reps.set(rk, {
          user_id: x.user_id != null ? x.user_id : null,
          salesperson: repName(x),
          n: 0, value: 0, residual: 0
        });
        const r = reps.get(rk); r.n++; r.value += t; r.residual += res;
      } else if (d.slice(0, 7) === lastMonth) {
        lastAny += t;
        if (Number(d.slice(8, 10)) <= domN) lastMTD += t;
      }
    }
    return { generated_at: new Date().toISOString(), currency: CFG.CURRENCY,
      month: thisMonth, value, count, collected,
      last_mtd: lastMTD, last_month_has_data: lastAny > 0,
      posted_rows: postedRows,
      by_rep: [...reps.values()].sort((a, b) => b.value - a.value) };
  }

  async function api(endpointKey, params) {
    // Raw-table adapters (used to be n8n snapshots — see docs/ARCHITECTURE.md).
    if (endpointKey === "rep_collections") return cachedApi("rep_collections", buildRepCollections);
    if (endpointKey === "rep_debt") return cachedApi("rep_debt", buildRepDebt);
    if (endpointKey === "collections") return cachedApi("collections", buildCollections);
    if (endpointKey === "invoices_month") return cachedApi("invoices_month", buildInvoicesMonth);
    if (endpointKey === "invoices_today") return buildInvoicesToday(); // uncached: it IS today

    if (endpointKey === "acks") {
      const rows = await sbGet(`alert_acks?select=order_id,order_name,level,amount_total,note,created_at&order=created_at.desc&limit=2000`);
      return { acks: rows || [] };
    }

    if (endpointKey === "alerts") {
      const since = new Date(Date.now() - 45 * 864e5).toISOString().slice(0, 10);
      const sel = "order_id,order_name,partner_name,salesperson,user_id,city,amount_total,state,level,reasons,date_order,create_date";
      const rows = await sbGet(
        `${CFG.TABLES.orders}?select=${sel}&level=in.(critical,warning)&create_date=gte.${since}` +
        `&order=date_order.desc,create_date.desc&limit=300`);
      const alerts = dedupeBy(rows || [], "order_id").map(r => ({ ...r, amount_total: Number(r.amount_total) || 0 }));
      const critical = alerts.filter(a => a.level === "critical").length;
      return { generated_at: new Date().toISOString(), currency: CFG.CURRENCY, count: alerts.length,
        critical, warning: alerts.length - critical, alerts };
    }

    if (endpointKey === "order") {
      const rows = await sbGet(`${CFG.TABLES.orders}?order_id=eq.${encodeURIComponent(params.id)}&limit=1`);
      if (!rows || !rows.length) return { found: false };
      const o = rows[0];
      return {
        found: true, currency: CFG.CURRENCY,
        order: {
          id: o.order_id, name: o.order_name, partner_name: o.partner_name, salesperson: o.salesperson, user_id: o.user_id,
          state: o.state, type_name: o.type_name, date_order: o.date_order, create_date: o.create_date,
          amount_total: o.amount_total,
          total_quantity: o.total_quantity, total_product: o.total_product,
          invoice_count: o.invoice_count,
          partner_credit_warning: o.partner_credit_warning
        },
        customer: o.customer || null,
        risk: { level: o.level, reasons: o.reasons || [] }
      };
    }

    throw new Error("unknown endpoint: " + endpointKey);
  }

  /* ---------------- write: acknowledge an alert ---------------- */
  async function ackAlert(order, note) {
    const prof = window.DASH_AUTH ? window.DASH_AUTH.profile() : null;
    const row = {
      order_id: order.order_id != null ? order.order_id : order.id,
      order_name: order.order_name || order.name || "",
      level: order.level || (order.risk && order.risk.level) || "",
      amount_total: Number(order.amount_total) || 0,
      note: note || null,
      acked_by: prof ? prof.user_id : null,
      acked_by_name: prof ? (prof.full_name || prof.username) : null
    };
    const base = CFG.SUPABASE_URL.replace(/\/$/, "");
    const res = await fetch(base + "/rest/v1/alert_acks", {
      method: "POST",
      headers: await authHeaders({ "Content-Type": "application/json", Prefer: "return=minimal" }),
      body: JSON.stringify(row)
    });
    if (!res.ok) { authFail(res); throw new Error("ack failed HTTP " + res.status); }
    return { ok: true };
  }

  /* ---------------- sound + notifications ---------------- */
  let audioCtx = null;
  function beep() {
    if (!CFG.SOUND_ENABLED || !soundOn) return;
    try {
      audioCtx = audioCtx || new (window.AudioContext || window.webkitAudioContext)();
      const now = audioCtx.currentTime;
      [880, 1320].forEach((freq, i) => {
        const o = audioCtx.createOscillator();
        const g = audioCtx.createGain();
        o.type = "sine"; o.frequency.value = freq;
        g.gain.setValueAtTime(0.0001, now + i * 0.18);
        g.gain.exponentialRampToValueAtTime(0.25, now + i * 0.18 + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, now + i * 0.18 + 0.16);
        o.connect(g); g.connect(audioCtx.destination);
        o.start(now + i * 0.18); o.stop(now + i * 0.18 + 0.18);
      });
    } catch (e) { /* ignore */ }
  }
  let soundOn = CFG.SOUND_ENABLED;
  function toggleSound() {
    soundOn = !soundOn;
    localStorage.setItem("dash_sound", soundOn ? "1" : "0");
    if (audioCtx && audioCtx.state === "suspended") audioCtx.resume();
    renderSoundBtn();
    if (soundOn) beep();
  }
  (function initSound() {
    const saved = localStorage.getItem("dash_sound");
    if (saved !== null) soundOn = saved === "1";
  })();

  function notify(title, body) {
    if (!("Notification" in window)) return;
    if (Notification.permission === "granted") new Notification(title, { body });
    else if (Notification.permission !== "denied") Notification.requestPermission();
  }

  function toast(msg, level) {
    let host = document.getElementById("toastHost");
    if (!host) { host = document.createElement("div"); host.id = "toastHost"; host.className = "toast-host"; document.body.appendChild(host); }
    const el = document.createElement("div");
    el.className = "toast toast-" + (level || "info");
    el.innerHTML = msg;
    host.appendChild(el);
    setTimeout(() => { el.classList.add("show"); }, 10);
    setTimeout(() => { el.classList.remove("show"); setTimeout(() => el.remove(), 300); }, 6000);
  }

  /* ---------------- chrome (header + nav) ----------------
     Pages are grouped by purpose; the nav draws a subtle divider between groups:
     main · sales (geography + people) · money (cash in + owed) · risk (alerts). */
  // Clean URLs (Vercel cleanUrls): no .html extension; overview is the root.
  const PAGES = [
    { key: "nav_overview", href: "/", id: "overview", group: "main" },
    { key: "nav_regions", href: "/regions", id: "regions", group: "sales" },
    { key: "nav_sales", href: "/salespeople", id: "sales", group: "sales" },
    { key: "nav_collections", href: "/collections", id: "collections", group: "money" },
    { key: "nav_debt", href: "/debt", id: "debt", group: "money" },
    { key: "nav_alerts", href: "/alerts", id: "alerts", group: "risk" },
    { key: "nav_admin", href: "/admin", id: "admin", group: "admin" }
  ];

  function renderSoundBtn() {
    const b = document.getElementById("soundBtn");
    if (!b) return;
    b.classList.toggle("on", soundOn);
    b.title = soundOn ? t("sound_on") : t("sound_off");
    b.textContent = soundOn ? "🔔" : "🔕";
  }

  function buildChrome(activeId) {
    document.documentElement.lang = LANG;
    document.documentElement.dir = isAR() ? "rtl" : "ltr";

    const header = document.getElementById("appHeader");
    if (header) {
      // Only show the pages this user may open (auth.js). The nav is UX —
      // the real enforcement is auth.js's guard + Row-Level Security.
      const A = window.DASH_AUTH;
      const prof = A ? A.profile() : null;
      const visible = A ? PAGES.filter(p => A.canView(p.id)) : PAGES;
      header.innerHTML = `
        <div class="hd-brand">
          <div class="hd-logo">DB</div>
          <div>
            <div class="hd-title">${t("brand")}</div>
            <div class="hd-sub">${t("sub")}</div>
          </div>
        </div>
        <nav class="hd-nav">
          ${visible.map((p, i) => {
            const sep = (i > 0 && visible[i - 1].group !== p.group) ? `<span class="nav-sep"></span>` : "";
            return sep + `<a href="${p.href}" class="${p.id === activeId ? "active" : ""}">${t(p.key)}</a>`;
          }).join("")}
        </nav>
        <div class="hd-tools">
          <span class="live-dot"><i></i>${t("live")}</span>
          <span id="updatedAt" class="updated" style="white-space:nowrap"></span>
          <button id="refreshBtn" class="icon-btn" type="button" title="${t("refresh_btn")}">🔄</button>
          <button id="soundBtn" class="icon-btn" type="button"></button>
          <button id="pdfBtn" class="icon-btn" type="button" title="${t("export_pdf")}">🖨️</button>
          <button id="langBtn" class="icon-btn lang" type="button">${t("lang_btn")}</button>
          ${prof ? `<span class="user-chip" title="${esc(prof.username)}">👤 ${esc(prof.full_name || prof.username)}</span>
          <button id="logoutBtn" class="icon-btn" type="button" title="${t("logout")}">⏻</button>` : ""}
        </div>`;
      document.getElementById("langBtn").addEventListener("click", () => {
        LANG = isAR() ? "en" : "ar";
        localStorage.setItem("dash_lang", LANG);
        location.reload();
      });
      // full refresh: reloading the page drops every in-memory cache (the
      // 4-min adapter cache included) and refetches ALL numbers from the DB
      document.getElementById("refreshBtn").addEventListener("click", () => location.reload());
      document.getElementById("soundBtn").addEventListener("click", toggleSound);
      // Export PDF = browser print dialog → "Save as PDF" (print stylesheet cleans the page)
      document.getElementById("pdfBtn").addEventListener("click", () => window.print());
      const lo = document.getElementById("logoutBtn");
      if (lo) lo.addEventListener("click", () => window.DASH_AUTH.signOut());
      renderSoundBtn();
      setUpdated(); // paint "synced from Odoo" now; pages refresh it on each poll
      paintScopeBanner(header);
    }
    // hide any panels whose source table an admin has switched off (global)
    applyDataSourceVisibility();
  }

  // Scoped-viewer banner: when this login is restricted to specific
  // salespersons, show it plainly under the header so the numbers are
  // self-explanatory. RLS is the actual control — this is only the honest
  // label. Rep names are resolved async from the salesperson master.
  function paintScopeBanner(header) {
    const A = window.DASH_AUTH;
    const scoped = A && A.isScoped && A.isScoped();
    let banner = document.getElementById("scopeBanner");
    if (!scoped) { if (banner) banner.remove(); return; }
    if (!banner) {
      banner = document.createElement("div");
      banner.id = "scopeBanner";
      banner.className = "scope-banner";
      banner.setAttribute("style",
        "padding:7px 16px;background:#fff7ed;border-bottom:1px solid #fed7aa;" +
        "color:#9a3412;font-size:12.5px;font-weight:600;line-height:1.4;");
      header.insertAdjacentElement("afterend", banner);
    }
    const ids = A.scopeIds() || [];
    banner.innerHTML = `👁 <b>${t("scope_viewing")}</b> <span id="scopeNames">…</span>`;
    loadSalespeopleMaster().then(reps => {
      const byId = new Map((reps || []).map(r => [Number(r.user_id), r.name]));
      const names = ids.map(id => byId.get(Number(id)) || ("#" + id));
      const el = document.getElementById("scopeNames");
      if (el) el.innerHTML = names.map(esc).join(isAR() ? "، " : ", ");
    }).catch(() => {});
  }

  // Live "synced from Odoo" clock in the header. Pipelines fire every 20 min,
  // so we count DOWN to the next expected sync and tick every second — the page
  // never has to be refreshed. When the countdown runs out we poll the DB
  // (forced, bypassing the 60s cache) until the new sync lands, then the clock
  // resets itself. Past ~45 min with no sync it turns amber (likely stalled
  // pipeline — check n8n). The `_ts` arg from callers is ignored on purpose;
  // the browser's poll time was misleading, the real value is loadLastSync().
  const SYNC_EVERY_MS = 20 * 60 * 1000;
  let _syncTick = null, _syncLastMs = 0, _syncNextFetch = 0;

  async function _syncRefetch(force) {
    try { const ts = await loadLastSync(force); _syncLastMs = ts ? new Date(ts).getTime() : 0; } catch (e) {}
    _syncNextFetch = Date.now() + (force ? 15000 : 45000);
  }
  function _clk(ms) {
    const s = Math.max(0, Math.floor(ms / 1000));
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  }
  function _paintSync() {
    const el = document.getElementById("updatedAt");
    if (!el) return;
    if (!_syncLastMs) { el.textContent = ""; el.removeAttribute("title"); el.style.color = ""; return; }
    const now = Date.now();
    const stale = now - _syncLastMs > 45 * 60000;
    const remain = (_syncLastMs + SYNC_EVERY_MS) - now;
    const tail = remain > 0 ? (t("next_sync") + " " + _clk(remain)) : t("sync_checking");
    el.textContent = (stale ? "⚠ " : "") + t("odoo_synced") + " " +
      fmtTime(new Date(_syncLastMs).toISOString()) + " · " + tail;
    el.style.color = stale ? "#f0a020" : "";
    if (stale) el.title = t("sync_delayed"); else el.removeAttribute("title");
    if (remain <= 0 && now >= _syncNextFetch) _syncRefetch(true); // overdue → poll hard for the new sync
  }
  // Pages call setUpdated() on each poll; it just ensures the self-running clock
  // is started (idempotent — one interval per page, ticks every second).
  function setUpdated() {
    if (_syncTick) return;
    _syncRefetch(false).then(_paintSync);
    _syncTick = setInterval(() => {
      if (Date.now() >= _syncNextFetch) _syncRefetch(false);
      _paintSync();
    }, 1000);
  }

  function stateLabel(s) { return (I18N[LANG].states[s]) || s || "—"; }
  function trustLabel(s) { return (I18N[LANG].trust[s]) || s || "—"; }

  /* ---------------- shared filter bar (date + salesperson + customer) ----------------
     Renders structured filter controls into `host` and calls onChange() on any change.
     opts: { date, rep, customer } booleans (default all true).
     Returns a controller: .setReps(names) to fill the dropdown from loaded rows,
     .values(), .setCount(n), and .match(row, {date,rep,cust}) where each value is the
     row's property name for that dimension (omit a key to skip that filter). */
  function filterBar(host, opts, onChange) {
    opts = opts || {};
    const showDate = opts.date !== false, showRep = opts.rep !== false, showCust = opts.customer !== false;
    const parts = [];
    if (showDate) parts.push(
      `<label class="fb-field"><span>${t("f_from")}</span><input id="fbFrom" class="fb-date" type="date"></label>`,
      `<label class="fb-field"><span>${t("f_to")}</span><input id="fbTo" class="fb-date" type="date"></label>`);
    if (showRep)  parts.push(`<select id="fbRep" class="fb-sel"><option value="">${t("f_rep_all")}</option></select>`);
    if (showCust) parts.push(`<input id="fbCust" class="search-box" type="search" placeholder="${t("f_customer_ph")}">`);
    parts.push(`<button id="fbClear" class="fb-clear" type="button">${t("f_clear")}</button>`);
    parts.push(`<span id="fbCount" class="fb-count"></span>`);
    host.innerHTML = parts.join("");
    const $ = id => document.getElementById(id);
    const fire = () => { onChange && onChange(); };
    ["fbFrom", "fbTo", "fbRep", "fbCust"].forEach(id => { const el = $(id); if (el) el.addEventListener("input", fire); });
    $("fbClear").addEventListener("click", () => {
      ["fbFrom", "fbTo", "fbCust"].forEach(id => { const el = $(id); if (el) el.value = ""; });
      const r = $("fbRep"); if (r) r.value = "";
      fire();
    });
    return {
      setReps(names) {
        const sel = $("fbRep"); if (!sel) return;
        const cur = sel.value;
        const uniq = [...new Set((names || []).filter(Boolean))].sort((a, b) => String(a).localeCompare(String(b)));
        sel.innerHTML = `<option value="">${t("f_rep_all")}</option>` +
          uniq.map(n => `<option${String(n) === cur ? " selected" : ""}>${n}</option>`).join("");
      },
      values() {
        return {
          from: ($("fbFrom") && $("fbFrom").value) || "", to: ($("fbTo") && $("fbTo").value) || "",
          rep: ($("fbRep") && $("fbRep").value) || "", cust: (($("fbCust") && $("fbCust").value) || "").trim().toLowerCase()
        };
      },
      setCount(n) { const c = $("fbCount"); if (c) c.textContent = (n != null ? n : "") + " " + t("f_results"); },
      match(row, fields) {
        fields = fields || {};
        const v = this.values();
        if (showDate && (v.from || v.to) && fields.date) {
          const d = String(row[fields.date] || "").slice(0, 10);
          if (!d) return false;
          if (v.from && d < v.from) return false;
          if (v.to && d > v.to) return false;
        }
        if (showRep && v.rep && fields.rep && String(row[fields.rep] || "") !== v.rep) return false;
        if (showCust && v.cust && fields.cust && !String(row[fields.cust] || "").toLowerCase().includes(v.cust)) return false;
        return true;
      }
    };
  }

  /* ---------------- governorate map (city -> Iraqi governorate) ----------------
     The Odoo `city` field is messy free-text mixing real governorates with
     districts/neighbourhoods. This dictionary buckets the known values into the
     18 governorates. Unrecognised cities fall back to "غير محدد / Unknown".
     To fix a misfiled city: add it to CITY2GOV with the right gov code. */
  const GOV = {
    baghdad:  { ar: "بغداد",       en: "Baghdad" },
    basra:    { ar: "البصرة",      en: "Basra" },
    nineveh:  { ar: "نينوى",       en: "Nineveh" },
    erbil:    { ar: "أربيل",       en: "Erbil" },
    kirkuk:   { ar: "كركوك",       en: "Kirkuk" },
    najaf:    { ar: "النجف",       en: "Najaf" },
    karbala:  { ar: "كربلاء",      en: "Karbala" },
    anbar:    { ar: "الأنبار",     en: "Anbar" },
    dhiqar:   { ar: "ذي قار",      en: "Dhi Qar" },
    babil:    { ar: "بابل",        en: "Babil" },
    diyala:   { ar: "ديالى",       en: "Diyala" },
    wasit:    { ar: "واسط",        en: "Wasit" },
    saladin:  { ar: "صلاح الدين",  en: "Saladin" },
    sulaymaniyah: { ar: "السليمانية", en: "Sulaymaniyah" },
    dohuk:    { ar: "دهوك",        en: "Dohuk" },
    muthanna: { ar: "المثنى",      en: "Muthanna" },
    qadisiyah:{ ar: "القادسية",    en: "Qadisiyah" },
    maysan:   { ar: "ميسان",       en: "Maysan" },
    // "nocity" = the order has NO city text at all (fix in Odoo, not here);
    // "unknown" = there IS a city text but the dictionary doesn't know it.
    nocity:   { ar: "بدون مدينة",  en: "No city" },
    unknown:  { ar: "غير محدد",    en: "Unknown" }
  };
  const CITY2GOV = {
    // Baghdad + its districts
    "بغداد": "baghdad", "الكرخ": "baghdad", "رصافة": "baghdad", "الرصافة": "baghdad",
    "المنصور": "baghdad", "الدوره": "baghdad", "الدورة": "baghdad", "الدوره حي دجلة": "baghdad",
    "ابو غريب": "baghdad", "كاظمية": "baghdad", "الكاظمية": "baghdad", "غزالية": "baghdad",
    "الغزالية": "baghdad", "شارع فلسطين": "baghdad", "رسالة": "baghdad", "الرسالة": "baghdad",
    "المدائن": "baghdad", "كرادة": "baghdad", "كراده": "baghdad", "طوبجي": "baghdad",
    "الجادرية": "baghdad", "حي الجامعه": "baghdad", "المأمون": "baghdad", "الخضراء": "baghdad",
    "الشرطة الخامسة": "baghdad", "الزعفرانية": "baghdad", "زعفرانيه": "baghdad", "الحسينية": "baghdad",
    // Nineveh (Mosul)
    "الموصل": "nineveh", "الحمدانية": "nineveh", "المشراق": "nineveh", "باب السراي": "nineveh",
    // Erbil
    "اربيل": "erbil", "أربيل": "erbil", "عينكاوة": "erbil", "شقلاوة": "erbil",
    // Kirkuk
    "كركوك": "kirkuk", "الحويجة": "kirkuk", "داقوق": "kirkuk", "الدبس": "kirkuk",
    // Najaf
    "النجف": "najaf", "المشخاب": "najaf", "الكوفة": "najaf",
    // Karbala
    "كربلاء": "karbala", "عين التمر": "karbala", "الهندية": "karbala",
    // Anbar
    "رمادي": "anbar", "الرمادي": "anbar", "هيت": "anbar", "فلوجة": "anbar", "الفلوجة": "anbar",
    "فلوجه": "anbar", "عامرية الفلوجة": "anbar", "الخالديه": "anbar", "خالدية": "anbar",
    "الخالدية": "anbar", "حديثة": "anbar", "راوه": "anbar", "الكرمة": "anbar", "البغدادي": "anbar",
    "حقلانية": "anbar", "عنه": "anbar", "القائم": "anbar", "الحبانية": "anbar", "المقام": "anbar",
    // Dhi Qar
    "الناصرية": "dhiqar", "الناصريه": "dhiqar", "الرفاعي": "dhiqar", "الشطرة": "dhiqar", "سوق الشيوخ": "dhiqar",
    // Babil
    "الحلة": "babil", "حلة": "babil", "المسيب": "babil", "مسيب": "babil", "الهاشمية": "babil",
    "المحاويل": "babil", "القاسم": "babil", "بابل": "babil",
    // Diyala
    "ديالى": "diyala", "بعقوبة": "diyala", "المقدادية": "diyala", "الخالص": "diyala", "بلدروز": "diyala",
    // Wasit
    "كوت": "wasit", "الكوت": "wasit", "الصويرة": "wasit", "صويرة": "wasit", "النعمانية": "wasit",
    "الحي": "wasit", "العزيزية": "wasit", "بدرة": "wasit",
    // Saladin
    "تكريت": "saladin", "سامراء": "saladin", "بلد": "saladin", "بيجي": "saladin", "العلم": "saladin",
    "الشرقاط": "saladin", "الدجيل": "saladin", "الضلوعية": "saladin", "بلد روز": "saladin",
    // Basra
    "البصرة": "basra", "الجبيلة": "basra", "الزبير": "basra", "ابو الخصيب": "basra", "القرنة": "basra", "المعقل": "basra",
    // Qadisiyah
    "الديوانية": "qadisiyah", "ديوانية": "qadisiyah", "عفك": "qadisiyah", "الشامية": "qadisiyah",
    // Muthanna
    "السماوة": "muthanna", "السماوه": "muthanna", "الرميثة": "muthanna", "الخضر": "muthanna",
    // Dohuk
    "دهوك": "dohuk", "زاخو": "dohuk", "زاويته": "dohuk",
    // Maysan
    "العمارة": "maysan", "ميسان": "maysan", "المجر": "maysan", "قلعة صالح": "maysan",
    // Sulaymaniyah
    "السليمانية": "sulaymaniyah", "السليمانيه": "sulaymaniyah",
    // ---- 2026-07 audit additions (high-confidence districts seen in live data) ----
    // Baghdad districts
    "اليوسفية": "baghdad", "الطارمية": "baghdad", "النهروان": "baghdad", "اليرموك": "baghdad",
    "الشعلة": "baghdad", "السيدية": "baghdad", "بسماية": "baghdad", "مدينة الصدر": "baghdad",
    "الوزيرية": "baghdad", "الحرية": "baghdad", "الشعب": "baghdad", "الصالحية": "baghdad",
    "العطيفية": "baghdad", "البياع": "baghdad", "الاعظمية": "baghdad", "الجهاد": "baghdad",
    // Anbar
    "عانة": "anbar", "الرطبة": "anbar",
    // Karbala (طويريج = local name of الهندية)
    "طويريج": "karbala",
    // Basra districts / towns
    "الهارثة": "basra", "القبلة": "basra", "ام قصر": "basra", "سفوان": "basra",
    "الفاو": "basra", "التنومة": "basra",
    // Nineveh districts / towns
    "القيارة": "nineveh", "بعشيقة": "nineveh", "برطلة": "nineveh", "تلعفر": "nineveh",
    "سنجار": "nineveh", "تلكيف": "nineveh",
    // Babil
    "الاسكندرية": "babil",
    // Dhi Qar
    "البطحة": "dhiqar",
    // Maysan
    "علي الغربي": "maysan",
    // ---- 2026-07-05 additions: every remaining unmapped string in live data,
    // assigned by cross-checking geography against the owning rep's territory
    // (each rep's OTHER orders are 68–100% one governorate) ----
    // Basra districts / variants
    "المدينة": "basra", "الطويسة": "basra", "الجمعيات": "basra", "الجزائر": "basra",
    "الحيانية": "basra", "الدير": "basra", "الخور": "basra", "الجنينة": "basra",
    "الجزيرة": "basra", "ابي الخصيب": "basra", "الامن الداخلي": "basra",
    // Nineveh (Mosul) districts
    "الفيصلية": "nineveh", "الساحل الأيسر": "nineveh", "المهندسين": "nineveh",
    "حي سومر": "nineveh", "الحود": "nineveh", "الزوية": "nineveh",
    // Baghdad ("الجاردية" = typo of الجادرية, "اعلام" = حي الإعلام)
    "الجاردية": "baghdad", "حي اور": "baghdad", "اعلام": "baghdad",
    // Babil
    "الحصوة": "babil", "ناحية الامام": "babil",
    // Karbala
    "المركزيه": "karbala",
    // Typos: كؤكوك = كركوك (Kirkuk) · ارييل = اربيل (Erbil)
    "كؤكوك": "kirkuk", "ارييل": "erbil",
    // Anbar (free-text landmark; rep territory is 100% Anbar)
    "قرب جامع الزبير ابن العوام": "anbar",
    // ---- 2026-07-08 additions: new unmapped values in live data, assigned
    // from the customer name itself (it contains the district/governorate)
    // cross-checked with the owning rep's territory ----
    // Basra (customer strings say "البصرة" explicitly; rep is 63% Basra)
    "داكير": "basra", "بريهة": "basra", "المطيحة": "basra",
    // Kirkuk — typo of كركوك (customer "مخزن أدريس / كركوك", rep 98% Kirkuk)
    "كركزك": "kirkuk",
    // Baghdad — المشاهدة is in Tarmiyah district, Baghdad governorate
    // (customer string says "طارمية")
    "المشاهدة": "baghdad",
    // Nineveh (customer "أسواق الشكره/القوسيات/الموصل", rep 100% Nineveh)
    "القوسيات": "nineveh"
  };
  // Normalize a messy free-text Arabic city string so more values match:
  // strip diacritics/tatweel, unify alef/ya/hamza/ta-marbuta spellings, collapse
  // whitespace, then drop a leading "ال" and common location-type prefixes.
  function normCity(s) {
    let n = String(s == null ? "" : s)
      .replace(/[ً-ْـ]/g, "")                   // tashkeel + tatweel
      .replace(/[أإآٱ]/g, "ا")                   // alef variants -> ا
      .replace(/[ىیۍ]/g, "ي")                    // alef maqsura + Persian yeh -> ي
      .replace(/ک/g, "ك")                        // Persian kaf -> Arabic kaf
      .replace(/ؤ/g, "و").replace(/ئ/g, "ي")     // hamza carriers
      .replace(/ة/g, "ه")                        // ta marbuta -> ha
      .replace(/\s+/g, " ")
      .trim();
    // Strip location-type prefixes. Written in NORMALIZED form (ة already -> ه)
    // so the match still works after the character folding above.
    n = n.replace(/^(محافظه|قضاء|ناحيه|مدينه|مركز|منطقه|حي)\s+/, "");
    n = n.replace(/^ال/, "");
    return n.trim();
  }
  // Build a normalized lookup ONCE: known city spellings + the governorate
  // names themselves (so a city value that is actually a governorate maps too).
  const CITY2GOV_N = {};
  Object.keys(CITY2GOV).forEach(k => { const nk = normCity(k); if (nk) CITY2GOV_N[nk] = CITY2GOV[k]; });
  Object.keys(GOV).forEach(code => { if (code === "unknown" || code === "nocity") return; const nk = normCity(GOV[code].ar); if (nk && !CITY2GOV_N[nk]) CITY2GOV_N[nk] = code; });
  // English governorate names too — Odoo's res.country.state may store them in
  // English ("Baghdad"), and the real governorate field routes through govOf().
  const GOV_EN2CODE = {};
  Object.keys(GOV).forEach(code => { if (code === "unknown" || code === "nocity") return; GOV_EN2CODE[GOV[code].en.toLowerCase()] = code; });
  function govResult(code) { return { key: code, ar: GOV[code].ar, en: GOV[code].en }; }
  function govOf(city) {
    const raw = (city == null ? "" : String(city)).trim();
    if (!raw || raw === "—") return govResult("nocity");
    const en = GOV_EN2CODE[raw.toLowerCase()];
    if (en) return govResult(en);                              // English governorate name
    if (CITY2GOV[raw]) return govResult(CITY2GOV[raw]);        // exact original (fast path)
    const n = normCity(raw);
    if (n && CITY2GOV_N[n]) return govResult(CITY2GOV_N[n]);   // normalized match
    // token match: a known place name appearing inside a longer free-text value
    // (e.g. "بغداد - الكرخ"). Require length >= 3 to avoid accidental hits.
    if (n) {
      const padded = " " + n + " ";
      for (const key in CITY2GOV_N) {
        if (key.length < 3) continue;
        if (n === key || padded.includes(" " + key + " ")) return govResult(CITY2GOV_N[key]);
      }
    }
    return govResult("unknown");
  }
  function govLabel(code) { const g = GOV[code] || GOV.unknown; return isAR() ? g.ar : g.en; }

  /* ---------------- raw-table loaders (for date-aware, client-side aggregation) ----
     Read dashboard_orders / dashboard_payments directly (anon key + RLS) with an
     optional date window, paginating past PostgREST's 1000-row cap. Pages use these
     so a date filter genuinely recomputes every KPI/chart instead of relying on the
     fixed-window snapshots. */
  function nextDay(ymd) { const d = new Date(ymd + "T00:00:00Z"); d.setUTCDate(d.getUTCDate() + 1); return d.toISOString().slice(0, 10); }
  // Defensive de-duplication: if the n8n sync ever appends instead of upserting,
  // the same order/payment can appear more than once and inflate every count and
  // total. Rows arrive newest-first, so we keep the FIRST occurrence per id.
  // NOTE: this only masks duplicates in the UI — the real fix is an upsert on the
  // primary key in the n8n pipeline (see docs/KNOWN_ISSUES.md).
  function dedupeBy(rows, idField) {
    const seen = new Set(); const out = [];
    for (const r of rows) {
      const id = r ? r[idField] : null;
      if (id == null) { out.push(r); continue; }
      if (seen.has(id)) continue;
      seen.add(id); out.push(r);
    }
    return out;
  }
  async function sbGetAll(pathAndQuery) {
    // Supabase caps every response at 1,000 rows. Each round trip costs
    // ~200ms from Iraq, so pages 2..N are fetched in PARALLEL: the first
    // request also returns the exact total (Prefer: count=exact), which
    // tells us how many more pages to launch at once. A 4-page window that
    // took ~1.8s serially takes ~2 round trips this way.
    const base = CFG.SUPABASE_URL.replace(/\/$/, "");
    const PAGE = 1000;
    const sep = pathAndQuery.includes("?") ? "&" : "?";
    const url = o => base + "/rest/v1/" + pathAndQuery + `${sep}limit=${PAGE}&offset=${o}`;
    const h = await authHeaders();
    const first = await fetch(url(0), {
      method: "GET", cache: "no-store",
      headers: Object.assign({}, h, { Prefer: "count=exact" })
    });
    if (!first.ok) { authFail(first); throw new Error("Supabase HTTP " + first.status); }
    const out = await first.json();
    const total = Number((first.headers.get("content-range") || "").split("/")[1]);
    if (out.length === PAGE && total > PAGE) {
      const offsets = [];
      for (let o = PAGE; o < Math.min(total, 100000); o += PAGE) offsets.push(o);
      const rest = await Promise.all(offsets.map(o =>
        fetch(url(o), { method: "GET", cache: "no-store", headers: h }).then(res => {
          if (!res.ok) { authFail(res); throw new Error("Supabase HTTP " + res.status); }
          return res.json();
        })));
      rest.forEach(rows => out.push(...rows));
    }
    return out;
  }
  async function loadOrders(o) {
    o = o || {};
    const sel = o.select || "order_id,order_name,partner_name,salesperson,user_id,city,state,type_name,amount_total,level,invoice_count,date_order,create_date,customer";
    const f = o.dateField || "create_date";
    // order_id tiebreaker: pagination pages are fetched separately, and a
    // non-unique sort lets tied rows drift between pages (rows lost/duplicated)
    let q = `${CFG.TABLES.orders}?select=${sel}&order=${f}.desc,order_id.desc`;
    if (o.from) q += `&${f}=gte.${o.from}`;
    if (o.to)   q += `&${f}=lt.${nextDay(o.to)}`;
    const rows = dedupeBy(await sbGetAll(q), "order_id");
    return rows.map(r => ({ ...r, amount_total: Number(r.amount_total) || 0 }));
  }
  // The salespeople MASTER (synced from Odoo) — pages feed it into the rep
  // dropdown so ALL reps are selectable, and resolve name→user_id for
  // uid-aware filtering (the same rep is spelled differently across
  // orders / invoices / payments). Cached per page load; never throws.
  let _repMaster = null;
  async function loadSalespeopleMaster() {
    if (_repMaster) return _repMaster;
    let rows;
    try { rows = await sbGet("salespeople?select=user_id,name&order=name"); }
    catch (e) { rows = []; }
    // Scoped viewer: the salespeople master is readable by everyone, so trim it
    // to the reps this login may actually see. This keeps every filter dropdown
    // (and the header banner) matching the data the user gets under RLS —
    // otherwise a scoped user would see all rep names in the filter. Unscoped
    // users (admins/management) keep the full list.
    const A = window.DASH_AUTH;
    const scope = A && A.scopeIds && A.scopeIds();
    if (scope) {
      const allow = new Set(scope.map(Number));
      rows = (rows || []).filter(r => allow.has(Number(r.user_id)));
    }
    _repMaster = rows || [];
    return _repMaster;
  }

  async function loadPayments(o) {
    o = o || {};
    const sel = o.select || "payment_id,date,amount,state,salesperson,user_id,partner_name,partner_id,journal";
    // Canceled payments are not money, and neither are REJECTED (bounced)
    // ones — excluding both keeps every page's cash KPIs honest. Pass
    // all:true to also get canceled/rejected rows (the Overview shows them
    // as their own status rows, Odoo-style, but never sums them as cash).
    // payment_id tiebreaker: many payments share one date; without a unique
    // sort, parallel pagination loses/duplicates rows at page boundaries
    let q = `dashboard_payments?select=${sel}&order=date.desc,payment_id.desc`;
    if (!o.all) q += `&state=not.in.(canceled,rejected)`;
    if (o.from) q += `&date=gte.${o.from}`;
    if (o.to)   q += `&date=lt.${nextDay(o.to)}`;
    const rows = dedupeBy(await sbGetAll(q), "payment_id");
    return rows.map(r => ({ ...r, amount: Number(r.amount) || 0 }));
  }

  /* ---------------- PWA: service worker ----------------
     Registered from the shared library so every page (including login)
     keeps the app installable. Requires HTTPS (or localhost). */
  if ("serviceWorker" in navigator &&
      (location.protocol === "https:" || ["localhost", "127.0.0.1"].includes(location.hostname))) {
    window.addEventListener("load", () => {
      navigator.serviceWorker.register("service-worker.js").catch(() => { /* non-fatal */ });
    });
  }

  /* ---------------- expose ---------------- */
  window.DASH = {
    t, isAR, lang: () => LANG, esc,
    fmtNum, fmtMoney, fmtMoneyFull, fmtDate, fmtTime,
    api, ackAlert, beep, toast, notify, buildChrome, setUpdated, loadLastSync, renderSoundBtn,
    stateLabel, trustLabel, filterBar,
    govOf, govLabel, GOV, loadOrders, loadPayments, loadSalespeopleMaster, sbGetAll, sbGet, sbWrite, nextDay, bagDay, addDays, weekStartSat,
    DATA_SOURCES, loadHiddenSources, setHiddenSources, applyDataSourceVisibility, applyHidden,
    cfg: CFG
  };
})();
