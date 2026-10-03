/* ============================================================
   Order drill-down modal — opened by clicking any order ID.
   Reads a single order from Supabase via DASH.api("order", { id }).
   ============================================================ */
(function () {
  const D = window.DASH;

  function ensureModal() {
    let m = document.getElementById("orderModal");
    if (m) return m;
    m = document.createElement("div");
    m.id = "orderModal";
    m.className = "modal-overlay";
    m.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true">
        <div class="modal-head">
          <div id="omTitle" class="modal-title">${D.t("order_details")}</div>
          <button id="omClose" class="icon-btn" type="button">✕</button>
        </div>
        <div id="omBody" class="modal-body"></div>
      </div>`;
    document.body.appendChild(m);
    m.addEventListener("click", (e) => { if (e.target === m) closeModal(); });
    m.querySelector("#omClose").addEventListener("click", closeModal);
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeModal(); });
    return m;
  }

  function closeModal() {
    const m = document.getElementById("orderModal");
    if (m) m.classList.remove("open");
  }

  function row(label, value, cls) {
    return `<div class="kv"><span class="kv-l">${label}</span><span class="kv-v ${cls || ""}">${value}</span></div>`;
  }

  async function openOrder(id) {
    const m = ensureModal();
    m.classList.add("open");
    const body = m.querySelector("#omBody");
    m.querySelector("#omTitle").textContent = D.t("order_details") + " #" + id;
    body.innerHTML = `<div class="loading">${D.t("loading")}</div>`;

    let data;
    try { data = await D.api("order", { id }); }
    catch (e) { body.innerHTML = `<div class="err">${D.t("error_load")}</div>`; return; }

    if (!data || !data.found) { body.innerHTML = `<div class="err">${D.t("not_found")}</div>`; return; }

    const o = data.order || {};
    const c = data.customer;
    const risk = data.risk || { level: "ok", reasons: [] };

    const badge = risk.level === "critical"
      ? `<span class="badge b-crit">${D.t("critical")}</span>`
      : risk.level === "warning"
        ? `<span class="badge b-warn">${D.t("warning")}</span>`
        : `<span class="badge b-ok">OK</span>`;

    const reasons = (risk.reasons && risk.reasons.length)
      ? `<ul class="risk-list">${risk.reasons.map(r =>
          `<li class="r-${D.esc(r.severity)}">${r.severity === "critical" ? "🔴" : "🟡"} ${D.esc(D.isAR() ? r.ar : r.en)}</li>`).join("")}</ul>`
      : `<div class="ok-msg">${D.t("no_risk")}</div>`;

    const orderGrid = `
      <div class="kv-grid">
        ${row(D.t("col_customer"), D.esc(o.partner_name || "—"))}
        ${row(D.t("col_rep"), D.esc(o.salesperson || "—"))}
        ${row(D.t("f_state"), D.stateLabel(o.state))}
        ${row(D.t("f_type"), D.esc(o.type_name || "—"))}
        ${row(D.t("f_date"), D.fmtDate(o.date_order))}
        ${row(D.t("f_qty"), D.fmtNum(o.total_quantity))}
        ${row(D.t("f_products"), D.fmtNum(o.total_product))}
        ${row(D.t("f_invoices"), D.fmtNum(o.invoice_count))}
        ${row(D.t("f_total"), D.fmtMoneyFull(o.amount_total), "strong")}
      </div>`;

    const custGrid = c ? `
      <div class="kv-grid">
        ${row(D.t("f_credit"), D.fmtMoneyFull(c.credit))}
        ${row(D.t("f_credit_limit"), D.fmtMoneyFull(c.credit_limit))}
        ${row(D.t("f_balance"), D.fmtMoneyFull(c.balance))}
        ${row(D.t("f_overdue"), D.fmtMoneyFull(c.vt_overdue_amount), c.vt_overdue_amount > 0 ? "danger" : "")}
        ${row(D.t("f_avg3m"), D.fmtMoneyFull(c.vt_avg_monthly_sales_3m))}
        ${row(D.t("f_pay6m"), D.fmtMoneyFull(c.vt_avg_monthly_payments_6m))}
        ${row(D.t("f_curmonth"), D.fmtMoneyFull(c.vt_current_month_sales))}
        ${row(D.t("f_dso"), c.days_sales_outstanding != null ? Math.round(c.days_sales_outstanding) : "—")}
        ${row(D.t("f_trust"), D.trustLabel(c.trust))}
        ${row(D.t("f_rank"), D.fmtNum(c.customer_rank))}
        ${row(D.t("f_invoiced"), D.fmtMoneyFull(c.total_invoiced))}
        ${row(D.t("f_payment"), D.esc(c.payment_method || "—"))}
      </div>` : `<div class="muted">—</div>`;

    const showReview = risk.level === "critical" || risk.level === "warning";
    const reviewBlock = showReview ? `
      <div class="modal-section review-box">
        <div class="ms-title">${D.t("risk_assessment")} · ${D.t("mark_reviewed")}</div>
        <textarea id="ackNote" class="ack-note" rows="2" placeholder="${D.t("add_note")}"></textarea>
        <button id="ackBtn" class="btn-review" type="button">${D.t("mark_reviewed")}</button>
      </div>` : "";

    body.innerHTML = `
      <div class="modal-hero">
        <div>
          <div class="mh-ref">${D.esc(o.name || ("#" + id))}</div>
          <div class="mh-name">${D.esc(o.partner_name || "")}</div>
        </div>
        <div class="mh-right">
          ${badge}
          <div class="mh-amt">${D.fmtMoneyFull(o.amount_total)}</div>
        </div>
      </div>
      <div class="modal-section"><div class="ms-title">${D.t("risk_assessment")}</div>${reasons}</div>
      ${reviewBlock}
      <div class="modal-section"><div class="ms-title">${D.t("order_details")}</div>${orderGrid}</div>
      <div class="modal-section"><div class="ms-title">${D.t("customer_profile")}</div>${custGrid}</div>`;

    const ackBtn = body.querySelector("#ackBtn");
    if (ackBtn) ackBtn.addEventListener("click", async () => {
      ackBtn.disabled = true;
      try {
        await D.ackAlert({ order_id: o.id, order_name: o.name, level: risk.level, amount_total: o.amount_total },
          (body.querySelector("#ackNote").value || "").trim());
        ackBtn.textContent = "✓ " + D.t("reviewed_ok");
        ackBtn.classList.add("done");
        D.toast(`<b>✓ ${D.t("reviewed_ok")}</b>${D.esc(o.name || ("#" + id))}`, "info");
      } catch (e) { ackBtn.disabled = false; D.toast(D.t("error_load"), "warning"); }
    });
  }

  // Delegate clicks on any element with data-order-id
  document.addEventListener("click", (e) => {
    const el = e.target.closest("[data-order-id]");
    if (el) { e.preventDefault(); openOrder(el.getAttribute("data-order-id")); }
  });

  window.DASH.openOrder = openOrder;
})();
