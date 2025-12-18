/**
 * =============================================================================
 *  Class:        UpcomingPaymentsServiceTest
 *  Project:      YMCA of San Francisco (YGSF)
 *  Purpose:      Unit tests for UpcomingPaymentsService. Verifies:
 *                  - Happy path grouping by [BSG + Payment Method]
 *                  - Stored Account vs Bill-to branching
 *                  - Fee/discount rollups and misc discount handling
 *                  - Next billing date computation presence
 *                  - Null account handling
 *
 *  Author:       Colby Wiley
 *  Created:      2025-11-02
 *  Last Updated: 2025-11-04
 *
 *  Notes:
 *    - Creates minimal synthetic data for GBG/BSG, TLIs, Stored Accounts, and
 *      Billing Schedules sufficient for the service queries and calculations.
 *    - TLI.Status is set to 'Close' to satisfy Is_Billable formula prerequisites.
 *    - Adjusted to align with occurrence-aware filtering: only items whose
 *      next occurrence equals the section’s earliest upcoming date are included.
 * =============================================================================
 */
@IsTest(seeAllData=false)
private class UpcomingPaymentsServiceTest {

    // --- tiny helper to clamp day to month length (mirrors service behavior) ---
    private static Date makeClampedDate(Integer year, Integer month, Integer day) {
        Integer lastDay = Date.daysInMonth(year, month);
        Integer useDay  = Math.min(day, lastDay);
        return Date.newInstance(year, month, useDay);
    }

    @TestSetup
    static void setup() {
        // Account
        Account acc = new Account(Name = 'Test Account');
        insert acc;

        // -------------- Global Billing Group / Billing Schedule Group #1 --------------
        Integer gbgDay = 5;
        TREX1__Global_Billing_Group__c gbg1 = new TREX1__Global_Billing_Group__c(
            TREX1__Monthly_Billing_Day__c = gbgDay,
            TREX1__Public_Name__c = 'GBG One',
            Name = 'GBG One'
        );
        insert gbg1;

        TREX1__Billing_Schedule_Group__c bsg1 = new TREX1__Billing_Schedule_Group__c(
            TREX1__bsg_Global_Billing_Group__c = gbg1.Id,
            TREX1__Global_Billing_Group_ID__c = gbg1.Id
        );
        insert bsg1;

        // -------------- Transaction & TLIs (Status must be 'Close' for Is_Billable) --------------
        TREX1__Transaction__c trans = new TREX1__Transaction__c();
        insert trans;
        trans.TREX1__Status__c = 'Close';
        update trans;

        // Fee TLI (ensure Description present so spi.tliDescription is not null)
        TREX1__Transaction_Line_Item__c tliFee = new TREX1__Transaction_Line_Item__c(
            TREX1__Account__c = acc.Id,
            TREX1__Transaction__c = trans.Id,
            TREX1__Description__c = 'Membership Fee (Desc)',
            TREX1__GL_Account_Deferred_Primary__c = '4000-01',
            TREX1__GL_Account_Deferred_Secondary__c = '4000-02',
            TREX1__GL_Percent_Deferred_Fee_Primary__c = 100,
            TREX1__GL_Percent_Deferred_Fee_Secondary__c = 0,
            TREX1__Initial_Fee_Revenue_Recognition_Policy__c = 'On Transaction Firmed',
            TREX1__Deferred_Revenue_Recognition_Policy__c = 'On Transaction Firmed'
        );
        insert tliFee;

        // Discount TLI
        TREX1__Transaction_Line_Item__c tliDisc = new TREX1__Transaction_Line_Item__c(
            TREX1__Account__c = acc.Id,
            TREX1__Transaction__c = trans.Id,
            TREX1__Description__c = 'Discount (Desc)',
            TREX1__GL_Account_Deferred_Primary__c = '4000-01',
            TREX1__GL_Account_Deferred_Secondary__c = '4000-02',
            TREX1__GL_Percent_Deferred_Fee_Primary__c = 100,
            TREX1__GL_Percent_Deferred_Fee_Secondary__c = 0,
            TREX1__Initial_Fee_Revenue_Recognition_Policy__c = 'On Transaction Firmed',
            TREX1__Deferred_Revenue_Recognition_Policy__c = 'On Transaction Firmed'
        );
        insert tliDisc;

        // -------------- Stored Accounts (minimal viable fields) --------------
        TPAY2__TP_StoredAccount__c saCard = new TPAY2__TP_StoredAccount__c(
            TPAY2__SA_Alias__c = 'MyCard',
            TPAY2__SA_CardScheme__c = 'Visa',
            TPAY2__SA_LastFourCardNumber__c = '1234',
            TPAY2__SA_ExpirationMonth__c = '07',
            TPAY2__SA_ExpirationYear__c = '27',
            TPAY2__SA_TenderType_Id__c = 'm0w8W000000PAw0QAG',
            TPAY2__SA_Credential_Id__c = 'm0t8W000000blPSQAY',
            TPAY2__SA_ObserverCreateAttempts__c = 1,
            TPAY2__SA_ObserverDeactivateAttempts__c = 0,
            TPAY2__SA_ObserverReplaceAttempts__c = 0,
            TPAY2__SA_ProcessorTokenState__c = 'Active',
            RecordTypeId = '0128W000000pE6jQAE',
            TPAY2__SA_Account__c = acc.Id,
            TPAY2__SA_Status__c = 'Active',
            TPAY2__SA_VP_PaymentAccountType__c = 'CreditCard',
            TPAY2__SA_BankTransferAccountType__c = null
        );
        insert saCard;

        // Alias that should be treated as "Bill to Account" by service logic
        TPAY2__TP_StoredAccount__c saHousehold = new TPAY2__TP_StoredAccount__c(
            TPAY2__SA_Alias__c = 'Household-Stored Account',
            TPAY2__SA_CardScheme__c = 'Mastercard',
            TPAY2__SA_LastFourCardNumber__c = '5678',
            TPAY2__SA_ExpirationMonth__c = '12',
            TPAY2__SA_ExpirationYear__c = '28',
            TPAY2__SA_TenderType_Id__c = 'm0w8W000000PAw0QAG',
            TPAY2__SA_Credential_Id__c = 'm0t8W000000blPSQAY',
            TPAY2__SA_ObserverCreateAttempts__c = 1,
            TPAY2__SA_ObserverDeactivateAttempts__c = 0,
            TPAY2__SA_ObserverReplaceAttempts__c = 0,
            TPAY2__SA_ProcessorTokenState__c = 'Active',
            RecordTypeId = '0128W000000pE6jQAE',
            TPAY2__SA_Account__c = acc.Id,
            TPAY2__SA_Status__c = 'Active',
            TPAY2__SA_VP_PaymentAccountType__c = 'CreditCard',
            TPAY2__SA_BankTransferAccountType__c = null
        );
        insert saHousehold;

        // -------------- Dates for schedule logic --------------
        Date today = Date.today();

        // Compute the section's expected next bill date for GBG day logic
        Date thisMonthGBG = makeClampedDate(today.year(), today.month(), gbgDay);
        Integer nm = (today.month() == 12) ? 1 : today.month() + 1;
        Integer ny = (today.month() == 12) ? today.year() + 1 : today.year();
        Date nextMonthGBG = makeClampedDate(ny, nm, gbgDay);
        Date expectedNext = (today.day() <= gbgDay) ? thisMonthGBG : nextMonthGBG;

        // -------------- Group 1 (Stored Account: MyCard) --------------
        // Monthly fee (positive), started in the past, never billed this month → next = expectedNext
        TREX1__Billing_Schedule__c bsMonthlyFee = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = null,
            TREX1__Term_Type__c = 'Monthly',
            TREX1__Start_Date__c = today.addMonths(-1), 
            TREX1__Last_Date_Billed__c = null,          
            TREX1__Amount__c = 50,
            TREX1__Billing_Schedule_Group__c = bsg1.Id,
            TREX1__Transaction_Line_Item__c = tliFee.Id,
            TREX1__TP2StoredAccount__c = saCard.Id
        );
        insert bsMonthlyFee;

        // One-time discount parented to the monthly fee (negative) with a different date
        TREX1__Billing_Schedule__c bsParentedDiscount = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = 1,
            TREX1__Term_Type__c = 'One Time',
            TREX1__Start_Date__c = expectedNext.addDays(1), 
            TREX1__End_Date__c = expectedNext.addDays(1),
            TREX1__Amount__c = -10,
            TREX1__Parent_Billing_Schedule__c = bsMonthlyFee.Id,
            TREX1__Billing_Schedule_Group__c = bsg1.Id,
            TREX1__Transaction_Line_Item__c = tliDisc.Id,
            TREX1__TP2StoredAccount__c = saCard.Id
        );
        insert bsParentedDiscount;

        // One-time misc discount (no parent) — align its start to the section's earliest occurrence
        TREX1__Billing_Schedule__c bsMiscDiscount = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = 1,
            TREX1__Term_Type__c = 'One Time',
            TREX1__Start_Date__c = expectedNext, 
            TREX1__End_Date__c = expectedNext,
            TREX1__Amount__c = -5,
            TREX1__Billing_Schedule_Group__c = bsg1.Id,
            TREX1__Transaction_Line_Item__c = tliDisc.Id,
            TREX1__TP2StoredAccount__c = saCard.Id
        );
        insert bsMiscDiscount;

        // Zero-amount one-time (ignored by service rollups now)
        TREX1__Billing_Schedule__c bsZero = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = null,
            TREX1__Term_Type__c = 'One Time',
            TREX1__Start_Date__c = today.addDays(4),
            TREX1__Amount__c = 0,
            TREX1__Billing_Schedule_Group__c = bsg1.Id,
            TREX1__Transaction_Line_Item__c = tliFee.Id,
            TREX1__TP2StoredAccount__c = saCard.Id
        );
        insert bsZero;

        // -------------- Group 2 (exercise additional payment keys & sorting) --------------
        TREX1__Global_Billing_Group__c gbg2 = new TREX1__Global_Billing_Group__c(
            TREX1__Monthly_Billing_Day__c = 10,
            TREX1__Public_Name__c = 'GBG Two',
            Name = 'GBG Two'
        );
        insert gbg2;

        TREX1__Billing_Schedule_Group__c bsg2 = new TREX1__Billing_Schedule_Group__c(
            TREX1__bsg_Global_Billing_Group__c = gbg2.Id,
            TREX1__Global_Billing_Group_ID__c = gbg2.Id
        );
        insert bsg2;

        // Bill-to (no stored account)
        TREX1__Billing_Schedule__c bsBillTo = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = null,
            TREX1__Term_Type__c = 'Monthly',
            TREX1__Start_Date__c = today,
            TREX1__Last_Date_Billed__c = null,
            TREX1__Amount__c = 30,
            TREX1__Billing_Schedule_Group__c = bsg2.Id,
            TREX1__Transaction_Line_Item__c = tliFee.Id
        );
        insert bsBillTo;

        // Household alias (treated as Bill-to by service logic)
        TREX1__Billing_Schedule__c bsHouseholdAliasBillTo = new TREX1__Billing_Schedule__c(
            TREX1__Is_Deactivated__c = false,
            TREX1__Billing_Finished__c = false,
            TREX1__Billing_Event_Count__c = 0,
            TREX1__Number_Of_Terms__c = null,
            TREX1__Term_Type__c = 'Monthly',
            TREX1__Start_Date__c = today,
            TREX1__Last_Date_Billed__c = null,
            TREX1__Amount__c = 15,
            TREX1__Billing_Schedule_Group__c = bsg2.Id,
            TREX1__Transaction_Line_Item__c = tliFee.Id,
            TREX1__TP2StoredAccount__c = saHousehold.Id 
        );
        insert bsHouseholdAliasBillTo;
    }

    @IsTest
    static void testGetUpcomingPayments_HappyPath() {
        Account acc = [SELECT Id FROM Account LIMIT 1];

        Test.startTest();
        List<UpcomingPaymentsService.SectionPaymentInfo> infos =
            UpcomingPaymentsService.getUpcomingPayments(acc.Id);
        Test.stopTest();

        System.assert(infos != null && infos.size() > 0, 'Expected at least one section');

        Boolean hasStored = false, hasBillTo = false;
        Integer totalItems = 0;
        Integer totalMiscDiscounts = 0;

        for (UpcomingPaymentsService.SectionPaymentInfo s : infos) {
            System.assertNotEquals(null, s.billingScheduleGroupId, 'Group id required');
            System.assertNotEquals(null, s.paymentMethod, 'Payment method required');
            System.assertNotEquals(null, s.items, 'Items list present');
            System.assertNotEquals(null, s.miscDiscounts, 'Misc discounts list present');
            System.assertNotEquals(null, s.feeTotal, 'Fee total populated');
            System.assertNotEquals(null, s.discountTotal, 'Discount total populated');
            System.assertNotEquals(null, s.netTotal, 'Net total populated');
            System.assertNotEquals(null, s.tliDescription, 'TLI Description populated');

            if (s.paymentMethod.displayType == 'STORED_ACCOUNT') hasStored = true;
            if (s.paymentMethod.displayType == 'BILL_TO_ACCOUNT') hasBillTo = true;

            totalItems += s.items.size();
            totalMiscDiscounts += s.miscDiscounts.size();

            // Next billing date should exist for monthly or one-time scenarios in this dataset
            System.assertNotEquals(null, s.nextBillingDate, 'Next billing date should be computed');
        }

        System.assert(hasStored, 'Should include a stored-account section');
        System.assert(hasBillTo, 'Should include a bill-to section');
        System.assert(totalItems > 0, 'Should include at least one fee item');
        System.assert(totalMiscDiscounts >= 1, 'Should include at least one misc discount');
    }

    @IsTest
    static void testEmptyForNullAccount() {
        Test.startTest();
        List<UpcomingPaymentsService.SectionPaymentInfo> infos =
            UpcomingPaymentsService.getUpcomingPayments(null);
        Test.stopTest();

        System.assertEquals(0, infos.size(), 'Null account should return empty list');
    }
}