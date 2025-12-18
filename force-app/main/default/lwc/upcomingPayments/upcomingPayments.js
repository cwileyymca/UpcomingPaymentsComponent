import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getUpcomingPayments from '@salesforce/apex/UpcomingPaymentsService.getUpcomingPayments';

export default class UpcomingPayments extends NavigationMixin(LightningElement) {
    @api recordId;

    @track groups = [];
    @track displayedGroups = [];
    @track error;
    @track loading = true;

    // Accordion: collapsed by default
    @track activeSectionNames = []; // none open

    // Pagination
    pageSize = 3;
    @track currentPage = 1;

    @wire(getUpcomingPayments, { accountId: '$recordId' })
    wiredPayments({ data, error }) {
        this.loading = false;
        if (data) {
            this.groups = (data || []).map((g) => {
                const mapped = {
                    id: g.sectionId,
                    groupId: g.billingScheduleGroupId,
                    name: g.billingScheduleGroupName,
                    nextDate: g.nextBillingDate ? this.formatDate(g.nextBillingDate) : null,
                    feeTotal: this.formatCurrency(g.feeTotal),
                    discountTotal: this.formatDiscount(g.discountTotal),
                    netTotal: this.formatCurrency(g.netTotal),
                    paymentMethod: this.mapPaymentMethod(g.paymentMethod),
                    tliDescription: g.tliDescription,
                    items: this.mapSectionItems(g.items),
                    miscDiscounts: this.mapDiscounts(g.miscDiscounts)
                };

                // Flatten into table rows (fees first, then discounts)
                mapped.detailRows = this.buildDetailRows(mapped);
                // Header text for the accordion section
                const pad = '\u00A0'.repeat(3); // three non-breaking spaces
                mapped.accordionLabel = `Details: ${pad}Fees ${mapped.feeTotal}${pad}·${pad}Discounts ${mapped.discountTotal}`;


                return mapped;
            });
            this.currentPage = 1;
            this.refreshDisplayed();
            this.error = undefined;
        } else if (error) {
            this.error = this.normalizeError(error);
            this.groups = [];
            this.displayedGroups = [];
            this.currentPage = 1;
        }
    }

  // Build rows: Description | Type | Amount (fees then discounts)
  buildDetailRows(group) {
    const rows = [];
    // Fees (from section items)
    (group.items || []).forEach((fee) => {
      rows.push({
        id: `fee-${fee.feeScheduleId}`,
        description: fee.tliDescription || fee.feeName || '—',
        type: 'Fee',
        amount: fee.feeAmount,
        recordId: fee.feeScheduleId 
      });
      // Discounts linked to this fee
      (fee.discounts || []).forEach((disc) => {
        rows.push({
          id: `disc-${disc.discountScheduleId}`,
          description: disc.tliDescription || disc.name || '—',
          type: 'Discount',
          amount: `-${disc.amount}`,
          recordId: disc.discountScheduleId 
        });
      });
    });
    // Misc discounts (no fee match)
    (group.miscDiscounts || []).forEach((disc) => {
      rows.push({
        id: `disc-misc-${disc.discountScheduleId}`,
        description: disc.tliDescription || disc.name || '—',
        type: 'Discount',
        amount: `-${disc.amount}`,
        recordId: disc.discountScheduleId 
      });
    });
    return rows;
  }
  
  // NEW: click handler that navigates to the Billing Schedule record
  handleRowLinkClick(event) {
    const recId = event.currentTarget?.dataset?.recordId;
    if (!recId) return;

    // Navigate to the standard record page (view action)
    this[NavigationMixin.Navigate]({
      type: 'standard__recordPage',
      attributes: {
        recordId: recId,
        objectApiName: 'TREX1__Billing_Schedule__c',
        actionName: 'view'
      }
    });
  }


    // Pagination helpers (unchanged)
    get totalPages() {
        return Math.max(1, Math.ceil(this.groups.length / this.pageSize));
    }
    get hasPagination() {
        return (this.groups?.length || 0) > this.pageSize;
    }
    get disablePrev() {
        return this.currentPage <= 1;
    }
    get disableNext() {
        return this.currentPage >= this.totalPages;
    }
    handleFirst() { if (!this.disablePrev) { this.currentPage = 1; this.refreshDisplayed(); } }
    handlePrev()  { if (!this.disablePrev) { this.currentPage -= 1; this.refreshDisplayed(); } }
    handleNext()  { if (!this.disableNext) { this.currentPage += 1; this.refreshDisplayed(); } }
    handleLast()  { if (!this.disableNext) { this.currentPage = this.totalPages; this.refreshDisplayed(); } }

    refreshDisplayed() {
        const start = (this.currentPage - 1) * this.pageSize;
        const end = start + this.pageSize;
        this.displayedGroups = this.groups.slice(start, end);
    }

    // Mapping/formatting
    mapPaymentMethod(pm) {
        if (!pm || pm.displayType === 'BILL_TO_ACCOUNT') {
            return { label: 'Bill to Account', nickname: null, cardType: null, endingIn: null, expiration: null, type: 'BILL_TO_ACCOUNT' };
        }
        return {
            label: null,
            nickname: pm.nickname,
            cardType: pm.cardType,
            endingIn: pm.endingIn,
            expiration: pm.expiration,
            type: 'STORED_ACCOUNT'
        };
    }

    mapSectionItems(items) {
        const arr = Array.isArray(items) ? items : [];
        return arr.map(it => ({
            feeName: it.feeName,
            feeAmount: this.formatCurrency(it.feeAmount),
            feeScheduleId: it.feeScheduleId,
            tliDescription: it.tliDescription,
            discounts: this.mapDiscounts(it.discounts)
        }));
    }

    mapDiscounts(discounts) {
        const arr = Array.isArray(discounts) ? discounts : [];
        return arr.map(d => ({
            name: d.name,
            amount: this.formatDiscount(d.amount), // positive coming from Apex; we format and add minus where shown
            discountScheduleId: d.discountScheduleId,
            parentFeeScheduleId: d.parentFeeScheduleId,
            tliDescription: d.tliDescription 
        }));
    }

    // Date/currency helpers (unchanged)
    formatDate(dateStr) {
        try {
            const [y, m, d] = (dateStr || '').split('-').map(s => parseInt(s, 10));
            const local = new Date(y, (m || 1) - 1, d || 1);
            const opts = { year: 'numeric', month: 'short', day: 'numeric' };
            return new Intl.DateTimeFormat(this.locale, opts).format(local);
        } catch (e) { return dateStr; }
    }
    formatCurrency(value) {
        const num = typeof value === 'number' ? value : Number(value);
        if (isNaN(num)) return value;
        try { return new Intl.NumberFormat(this.locale, { style: 'currency', currency: this.currency }).format(num); }
        catch (e) { return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(num); }
    }
    formatDiscount(value) {
        const num = typeof value === 'number' ? value : Number(value);
        if (isNaN(num)) return value;
        try { return new Intl.NumberFormat(this.locale, { style: 'currency', currency: this.currency }).format(num); }
        catch (e) { return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(num); }
    }
    get locale() { return navigator.language || 'en-US'; }
    get currency() { return 'USD'; }
    get hasData()  { return this.groups && this.groups.length > 0; }

    normalizeError(error) {
        if (Array.isArray(error?.body)) return error.body.map(e => e.message).join(', ');
        if (error?.body?.message) return error.body.message;
        return error?.statusText || 'Unknown error';
    }

    // Accordion handler (optional; not strictly required)
    handleAccordionToggle(event) {
        this.activeSectionNames = event.detail.openSections;
    }
}
