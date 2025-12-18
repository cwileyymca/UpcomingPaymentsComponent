/**
 * =============================================================================
 *  Class:        UpcomingPaymentsService
 *  Project:      YMCA of San Francisco (YGSF)
 *  Purpose:      Builds upcoming payment sections for an Account by grouping
 *                billable Billing Schedules by [Billing Schedule Group + Payment Method],
 *                computing next billing date, and rolling up fees/discounts.
 *
 *  Exposed To:   Lightning (Aura/LWC) via @AuraEnabled methods
 *  Caching:      getUpcomingPayments() is cacheable=true (safe for wire/adapters)
 *
 *  Author:       Colby Wiley
 *  Created:      2025-11-02
 *  Last Updated: 2025-11-04
 *
 *  Notes:
 *    - Payment method “BILL_TO_ACCOUNT” used when no Stored Account or alias is
 *      'Household-Stored Account'; otherwise “STORED_ACCOUNT”.
 *    - Next billing date logic (per schedule, then per section = earliest):
 *        • Monthly: uses GBG monthly day; respects Start Date, Last Billed, and month length.
 *        • One Time: Start Date.
 *    - Totals/rows: built only from items that bill on the section’s next date.
 * =============================================================================
 */
public with sharing class UpcomingPaymentsService {

    // ---------------------------
    // DTOs (exposed to LWC/Aura)
    // ---------------------------

    public class PaymentMethodInfo {
        @AuraEnabled public String displayType;   // 'STORED_ACCOUNT' | 'BILL_TO_ACCOUNT'
        @AuraEnabled public String nickname;
        @AuraEnabled public String cardType;
        @AuraEnabled public String endingIn;
        @AuraEnabled public String expiration;    // MM/YY
        @AuraEnabled public Id     storedAccountId;
    }

    /** Represents a discount applied to a fee item. */
    public class DiscountItem {
        @AuraEnabled public String  name;
        @AuraEnabled public Decimal amount;               // positive value for display
        @AuraEnabled public Id     discountScheduleId;
        @AuraEnabled public Id     parentFeeScheduleId;
        @AuraEnabled public String tliDescription;
    }

    /** Represents a fee item and its linked discounts. */
    public class SectionItem {
        @AuraEnabled public String              feeName;
        @AuraEnabled public Decimal             feeAmount;
        @AuraEnabled public Id                  feeScheduleId;
        @AuraEnabled public String              tliDescription;
        @AuraEnabled public List<DiscountItem>  discounts;
    }

    /** One UI section per [Billing Schedule Group + Payment Method Key]. */
    public class SectionPaymentInfo {
        @AuraEnabled public String              sectionId; // groupId + '|' + paymentKey
        @AuraEnabled public Id                  billingScheduleGroupId;
        @AuraEnabled public String              billingScheduleGroupName;
        @AuraEnabled public Date                nextBillingDate;
        @AuraEnabled public Decimal             feeTotal;
        @AuraEnabled public Decimal             discountTotal;
        @AuraEnabled public Decimal             netTotal;
        @AuraEnabled public PaymentMethodInfo   paymentMethod;
        @AuraEnabled public String              tliDescription;
        @AuraEnabled public List<SectionItem>   items;
        @AuraEnabled public List<DiscountItem>  miscDiscounts; // discounts without a fee match
    }

    // ---------------------------
    // Public API
    // ---------------------------

    /**
     * Returns upcoming payment sections for the given Account.
     */
    @AuraEnabled(cacheable=true)
    public static List<SectionPaymentInfo> getUpcomingPayments(Id accountId) {
        if (accountId == null) return new List<SectionPaymentInfo>();

        // Billable Billing Schedules whose TLI points to the Account; include BSG→GBG & Stored Account fields
        List<TREX1__Billing_Schedule__c> schedules = [
            SELECT Id, Name,
                   TREX1__Is_Billable__c,
                   TREX1__Term_Type__c,
                   TREX1__Start_Date__c,
                   TREX1__End_Date__c,
                   TREX1__Last_Date_Billed__c,
                   TREX1__Amount__c,
                   TREX1__Parent_Billing_Schedule__c,
                   TREX1__Billing_Schedule_Group__c,
                   TREX1__Billing_Schedule_Group__r.Name,
                   TREX1__Billing_Schedule_Group__r.TREX1__bsg_Global_Billing_Group__c,
                   TREX1__Billing_Schedule_Group__r.TREX1__bsg_Global_Billing_Group__r.Id,
                   TREX1__Billing_Schedule_Group__r.TREX1__bsg_Global_Billing_Group__r.Name,
                   TREX1__Billing_Schedule_Group__r.TREX1__bsg_Global_Billing_Group__r.TREX1__Monthly_Billing_Day__c,
                   TREX1__Transaction_Line_Item__c,
                   TREX1__Transaction_Line_Item__r.TREX1__Account__c,
                   TREX1__Transaction_Line_Item__r.TREX1__Description__c,
                   TREX1__TP2StoredAccount__c,
                   TREX1__TP2StoredAccount__r.TPAY2__SA_Alias__c,
                   TREX1__TP2StoredAccount__r.TPAY2__SA_CardScheme__c,
                   TREX1__TP2StoredAccount__r.TPAY2__SA_LastFourCardNumber__c,
                   TREX1__TP2StoredAccount__r.TPAY2__SA_ExpirationMonth__c,
                   TREX1__TP2StoredAccount__r.TPAY2__SA_ExpirationYear__c,
                   TREX1__Number_Of_Terms__c,
                   TREX1__Billing_Event_Count__c
            FROM TREX1__Billing_Schedule__c
            WHERE TREX1__Is_Billable__c = true
              AND TREX1__Transaction_Line_Item__r.TREX1__Account__c = :accountId
              AND TREX1__Billing_Schedule_Group__c != null
        ];
        if (schedules.isEmpty()) return new List<SectionPaymentInfo>();

        // Group by Billing Schedule Group
        Map<Id, List<TREX1__Billing_Schedule__c>> byGroup = new Map<Id, List<TREX1__Billing_Schedule__c>>();
        Map<Id, String> groupNames = new Map<Id, String>();
        for (TREX1__Billing_Schedule__c bs : schedules) {
            Id gid = bs.TREX1__Billing_Schedule_Group__c;
            if (!byGroup.containsKey(gid)) {
                byGroup.put(gid, new List<TREX1__Billing_Schedule__c>());
                groupNames.put(gid, (bs.TREX1__Billing_Schedule_Group__r != null) ? bs.TREX1__Billing_Schedule_Group__r.Name : null);
            }
            byGroup.get(gid).add(bs);
        }

        List<SectionPaymentInfo> results = new List<SectionPaymentInfo>();
        Date today = Date.today();

        for (Id groupId : byGroup.keySet()) {
            List<TREX1__Billing_Schedule__c> groupSchedules = byGroup.get(groupId);
            if (groupSchedules == null || groupSchedules.isEmpty()) continue;

            // Monthly Billing Day from GBG
            Integer monthlyBillingDay = null;
            for (TREX1__Billing_Schedule__c tmp : groupSchedules) {
                if (tmp.TREX1__Billing_Schedule_Group__r != null &&
                    tmp.TREX1__Billing_Schedule_Group__r.TREX1__bsg_Global_Billing_Group__r != null) {
                    monthlyBillingDay =
                        (Integer) tmp.TREX1__Billing_Schedule_Group__r
                                  .TREX1__bsg_Global_Billing_Group__r
                                  .TREX1__Monthly_Billing_Day__c;
                    break;
                }
            }

            // Subgroup by payment key within group
            Map<String, List<TREX1__Billing_Schedule__c>> byPaymentKey = new Map<String, List<TREX1__Billing_Schedule__c>>();
            Map<String, PaymentMethodInfo> paymentInfoByKey = new Map<String, PaymentMethodInfo>();

            for (TREX1__Billing_Schedule__c bs : groupSchedules) {
                String alias = (bs.TREX1__TP2StoredAccount__r != null)
                    ? (String) bs.TREX1__TP2StoredAccount__r.TPAY2__SA_Alias__c
                    : null;

                Boolean isBillTo = (bs.TREX1__TP2StoredAccount__c == null) || (alias != null && alias.contains('Household-Stored Account'));

                String key;
                PaymentMethodInfo pmi = new PaymentMethodInfo();

                if (isBillTo) {
                    key = 'BILL_TO_ACCOUNT';
                    pmi.displayType = 'BILL_TO_ACCOUNT';
                } else {
                    key = 'STORED_ACCOUNT:' + String.valueOf(bs.TREX1__TP2StoredAccount__c);
                    pmi.displayType     = 'STORED_ACCOUNT';
                    pmi.nickname        = alias;
                    pmi.cardType        = (bs.TREX1__TP2StoredAccount__r != null) ? bs.TREX1__TP2StoredAccount__r.TPAY2__SA_CardScheme__c : null;
                    pmi.endingIn        = (bs.TREX1__TP2StoredAccount__r != null) ? bs.TREX1__TP2StoredAccount__r.TPAY2__SA_LastFourCardNumber__c : null;
                    String mm           = (bs.TREX1__TP2StoredAccount__r != null) ? (String) bs.TREX1__TP2StoredAccount__r.TPAY2__SA_ExpirationMonth__c : null;
                    String yy           = (bs.TREX1__TP2StoredAccount__r != null) ? (String) bs.TREX1__TP2StoredAccount__r.TPAY2__SA_ExpirationYear__c : null;
                    pmi.expiration      = formatExpiration(mm, yy);
                    pmi.storedAccountId = bs.TREX1__TP2StoredAccount__c;
                }

                if (!byPaymentKey.containsKey(key)) {
                    byPaymentKey.put(key, new List<TREX1__Billing_Schedule__c>());
                    paymentInfoByKey.put(key, pmi);
                }
                byPaymentKey.get(key).add(bs);
            }

            // Build sections per payment key (occurrence-aware)
            for (String key : byPaymentKey.keySet()) {
                List<TREX1__Billing_Schedule__c> items = byPaymentKey.get(key);

                // Map each schedule to its next occurrence (null if none)
                Map<Id, Date> nextById = new Map<Id, Date>();
                for (TREX1__Billing_Schedule__c bs : items) {
                    Date occ = nextOccurrenceForSchedule(bs, monthlyBillingDay, today);
                    if (occ != null) nextById.put(bs.Id, occ);
                }

                // Section next date = earliest occurrence across items
                Date sectionNext = null;
                for (Date d : nextById.values()) {
                    if (sectionNext == null || d < sectionNext) sectionNext = d;
                }

                // Filter items to those that actually bill on the section's next date
                List<TREX1__Billing_Schedule__c> itemsForThisCycle = new List<TREX1__Billing_Schedule__c>();
                if (sectionNext != null) {
                    for (TREX1__Billing_Schedule__c bs : items) {
                        Date occ = nextById.get(bs.Id);
                        if (occ != null && occ == sectionNext) itemsForThisCycle.add(bs);
                    }
                }

                // Compute totals/linkages ONLY from items for this cycle
                Decimal feeTotal = 0, discountTotal = 0, netTotal = 0;

                Map<Id, TREX1__Billing_Schedule__c> feeById = new Map<Id, TREX1__Billing_Schedule__c>();
                Map<Id, List<TREX1__Billing_Schedule__c>> discountsByParent = new Map<Id, List<TREX1__Billing_Schedule__c>>();
                List<TREX1__Billing_Schedule__c> miscDiscounts = new List<TREX1__Billing_Schedule__c>();

                for (TREX1__Billing_Schedule__c bs : itemsForThisCycle) {
                    if (bs.TREX1__Amount__c != null) {
                        netTotal += bs.TREX1__Amount__c;
                        if (bs.TREX1__Amount__c > 0) {
                            feeTotal += bs.TREX1__Amount__c;
                            feeById.put(bs.Id, bs);
                        } else if (bs.TREX1__Amount__c < 0) {
                            discountTotal += (bs.TREX1__Amount__c).abs();
                            if (bs.TREX1__Parent_Billing_Schedule__c != null) {
                                if (!discountsByParent.containsKey(bs.TREX1__Parent_Billing_Schedule__c)) {
                                    discountsByParent.put(bs.TREX1__Parent_Billing_Schedule__c, new List<TREX1__Billing_Schedule__c>());
                                }
                                discountsByParent.get(bs.TREX1__Parent_Billing_Schedule__c).add(bs);
                            } else {
                                miscDiscounts.add(bs);
                            }
                        }
                    }
                }

                // Build SectionItems (fees with their linked discounts)
                List<SectionItem> sectionItems = new List<SectionItem>();
                for (Id feeId : feeById.keySet()) {
                    TREX1__Billing_Schedule__c fee = feeById.get(feeId);
                    SectionItem si = new SectionItem();
                    si.feeName        = fee.Name;
                    si.feeAmount      = (fee.TREX1__Amount__c != null) ? fee.TREX1__Amount__c.setScale(2) : 0;
                    si.feeScheduleId  = fee.Id;
                    si.tliDescription = (fee.TREX1__Transaction_Line_Item__r != null)
                        ? (String) fee.TREX1__Transaction_Line_Item__r.TREX1__Description__c
                        : null;
                    si.discounts      = new List<DiscountItem>();

                    if (discountsByParent.containsKey(feeId)) {
                        for (TREX1__Billing_Schedule__c disc : discountsByParent.get(feeId)) {
                            DiscountItem di = new DiscountItem();
                            di.name                 = disc.Name;
                            di.amount               = (disc.TREX1__Amount__c != null) ? disc.TREX1__Amount__c.abs().setScale(2) : 0;
                            di.discountScheduleId   = disc.Id;
                            di.parentFeeScheduleId  = feeId;
                            di.tliDescription       = (disc.TREX1__Transaction_Line_Item__r != null)
                                ? (String) disc.TREX1__Transaction_Line_Item__r.TREX1__Description__c
                                : null;
                            si.discounts.add(di);
                        }
                    }
                    sectionItems.add(si);
                }

                // Build misc discounts (not linked to a fee in this section)
                List<DiscountItem> misc = new List<DiscountItem>();
                for (TREX1__Billing_Schedule__c disc : miscDiscounts) {
                    DiscountItem di = new DiscountItem();
                    di.name                = disc.Name;
                    di.amount              = (disc.TREX1__Amount__c != null) ? disc.TREX1__Amount__c.abs().setScale(2) : 0;
                    di.discountScheduleId  = disc.Id;
                    di.parentFeeScheduleId = disc.TREX1__Parent_Billing_Schedule__c;
                    di.tliDescription      = (disc.TREX1__Transaction_Line_Item__r != null)
                        ? (String) disc.TREX1__Transaction_Line_Item__r.TREX1__Description__c
                        : null;
                    misc.add(di);
                }

                // Assemble section (add only if there’s something this cycle)
                if (sectionNext != null && (feeTotal != 0 || discountTotal != 0)) {
                    SectionPaymentInfo spi = new SectionPaymentInfo();
                    spi.sectionId               = String.valueOf(groupId) + '|' + key;
                    spi.billingScheduleGroupId  = groupId;
                    spi.billingScheduleGroupName= groupNames.get(groupId);
                    spi.nextBillingDate         = sectionNext;
                    spi.feeTotal                = feeTotal.setScale(2);
                    spi.discountTotal           = discountTotal.setScale(2);
                    spi.netTotal                = netTotal.setScale(2);
                    spi.paymentMethod           = paymentInfoByKey.get(key);
                    spi.tliDescription          = (itemsForThisCycle != null && !itemsForThisCycle.isEmpty() &&
                                                   itemsForThisCycle[0].TREX1__Transaction_Line_Item__r != null)
                                                  ? itemsForThisCycle[0].TREX1__Transaction_Line_Item__r.TREX1__Description__c
                                                  : null;
                    spi.items                   = sectionItems;
                    spi.miscDiscounts           = misc;
                    results.add(spi);
                }
            }
        }

        // Sort by next billing date ascending (nulls last, though we never add nulls)
        results = sortSectionsByNextDate(results);
        return results;
    }

    // ---------------------------
    // Date / occurrence helpers
    // ---------------------------

    private static Boolean containsMonthly(List<TREX1__Billing_Schedule__c> listIn) {
        for (TREX1__Billing_Schedule__c bs : listIn) {
            if (bs.TREX1__Term_Type__c == 'Monthly') return true;
        }
        return false;
    }

    private static Date getLatestDate(List<Date> dates) {
        Date latest = null;
        for (Date d : dates) {
            if (d == null) continue;
            if (latest == null || d > latest) latest = d;
        }
        return latest;
    }

    private static Date getEarliestDate(List<Date> dates) {
        Date earliest = null;
        for (Date d : dates) {
            if (d == null) continue;
            if (earliest == null || d < earliest) earliest = d;
        }
        return earliest;
    }

    /** Builds a date clamped to the last day of the given month. */
    private static Date makeClampedDate(Integer year, Integer month, Integer day) {
        Integer lastDay = Date.daysInMonth(year, month);
        Integer useDay  = Math.min(day, lastDay);
        return Date.newInstance(year, month, useDay);
    }

    /**
     * Earliest bill date for a MONTHLY schedule respecting Start Date, Last Billed, and GBG day.
     */
    private static Date nextMonthlyOccurrence(
    Integer monthlyDay,
    Date startDate,
    Date lastBilled,
    Date endDate,         // <-- NEW
    Date today
){
    if (monthlyDay == null) return null;
    Integer day = Math.max(1, Math.min(31, monthlyDay));

    if (lastBilled != null && lastBilled.year() == today.year() && lastBilled.month() == today.month()) {
        Integer nm1 = (today.month() == 12) ? 1 : today.month() + 1;
        Integer ny1 = (today.month() == 12) ? today.year() + 1 : today.year();
        Date cand = makeClampedDate(ny1, nm1, day);
        return (endDate != null && cand > endDate) ? null : cand;   // <-- end-date guard
    }

    Date thisMonth = makeClampedDate(today.year(), today.month(), day);
    Integer nm = (today.month() == 12) ? 1 : today.month() + 1;
    Integer ny = (today.month() == 12) ? today.year() + 1 : today.year();
    Date nextMonth = makeClampedDate(ny, nm, day);

    // If Start Date is in a future month, first bill = that month’s GBG day
    if (startDate != null) {
        if (startDate.year() > today.year()
         || (startDate.year() == today.year() && startDate.month() > today.month())) {
            Date cand = makeClampedDate(startDate.year(), startDate.month(), day);
            return (endDate != null && cand > endDate) ? null : cand;  // <-- guard
        }
        if (startDate.year() == today.year() && startDate.month() == today.month()) {
            Date cand = (today.day() <= day) ? thisMonth : nextMonth;
            return (endDate != null && cand > endDate) ? null : cand;  // <-- guard
        }
    }

    Date cand2 = (today.day() <= day) ? thisMonth : nextMonth;
    return (endDate != null && cand2 > endDate) ? null : cand2;        // <-- guard
}

    /**
     * Returns the next occurrence for a schedule (null if none).
     * - Amount must be non-zero to participate in UI rollups.
     * - Number_Of_Terms = 1 and already billed once → no future occurrence.
     */
    private static Date nextOccurrenceForSchedule(
    TREX1__Billing_Schedule__c bs,
    Integer monthlyDay,
    Date today
){
    if (bs.TREX1__Amount__c == null || bs.TREX1__Amount__c == 0) return null;

    Integer terms = (bs.TREX1__Number_Of_Terms__c == null) ? null : bs.TREX1__Number_Of_Terms__c.intValue();
    Integer billedCount = (bs.TREX1__Billing_Event_Count__c == null) ? null : bs.TREX1__Billing_Event_Count__c.intValue();
    if (terms != null && terms == 1 && billedCount != null && billedCount >= 1) return null;

    Date startDate = bs.TREX1__Start_Date__c;
    Date endDate   = bs.TREX1__End_Date__c;    // <-- NEW

    String term = bs.TREX1__Term_Type__c;
    if (term == 'One Time') {
        // Only participate if Start Date exists and is within window (≤ End Date if provided)
        if (startDate == null) return null;
        if (endDate != null && startDate > endDate) return null;
        return startDate;
    } else if (term == 'Monthly') {
        Date cand = nextMonthlyOccurrence(
            monthlyDay,
            startDate,
            bs.TREX1__Last_Date_Billed__c,
            endDate,                     // <-- pass End Date
            today
        );
        return cand; // (cand may be null if beyond end window)
    }
    return null;
}


    // ---------------------------
    // Formatting helpers
    // ---------------------------

    private static String leftPad2(String s) {
        if (s == null) return null;
        return (s.length() == 1) ? '0' + s : s;
    }

    /** Formats expiration as MM/YY given month and year strings (handles 4-digit year). */
    private static String formatExpiration(String monthStr, String yearStr) {
        if (String.isBlank(monthStr) || String.isBlank(yearStr)) return null;
        String mm = leftPad2(monthStr.trim());
        String yy = yearStr.trim();
        if (yy.length() == 4) yy = yy.substring(2);
        if (yy.length() > 2)  yy = yy.right(2);
        return mm + '/' + yy;
    }

    // ---------------------------
    // Sorting
    // ---------------------------

    /** Sorts sections by nextBillingDate ascending (nulls last). */
    private static List<SectionPaymentInfo> sortSectionsByNextDate(List<SectionPaymentInfo> input) {
        if (input == null || input.isEmpty()) return input;
        List<SectionPaymentInfo> items = new List<SectionPaymentInfo>(input);
        items.sort(new SectionPaymentInfoDateComparator());
        return items;
    }

    /** Comparator for nextBillingDate (nulls last). */
    public class SectionPaymentInfoDateComparator implements System.Comparator<SectionPaymentInfo> {
        public Integer compare(SectionPaymentInfo a, SectionPaymentInfo b) {
            Date da = (a != null) ? a.nextBillingDate : null;
            Date db = (b != null) ? b.nextBillingDate : null;
            if (da == null && db == null) return 0;
            if (da == null) return 1;   // nulls last
            if (db == null) return -1;  // nulls last
            if (da == db)  return 0;
            return (da < db) ? -1 : 1;
        }
    }
}
