public with sharing class M3ter_Ctrl {
    @AuraEnabled
    public static String listBills(String accountId, String usageEntitlementAccountId) {
        try {
            HttpCalloutService listService = new HTTPCalloutService('M3ter_ListBills');
            if (String.isNotBlank(accountId)) {
                listService.setURLParameter('accountId', accountId);
            }
            listService.setURLParameter('status', 'PENDING');
            
            HttpResponse listResponse = listService.sendRequest();
            
            if (listResponse.getStatusCode() != 200) {
                throw new CalloutException('ListBills API failed. Status: ' + listResponse.getStatusCode() + ' Body: ' + listResponse.getBody());
            }

            // Safely parse the JSON 
            Object untypedResponse = JSON.deserializeUntyped(listResponse.getBody());
            List<Map<String, Object>> actualBills = new List<Map<String, Object>>();
            
            if (untypedResponse instanceof Map<String, Object>) {
                Map<String, Object> rootMap = (Map<String, Object>) untypedResponse;
                if (rootMap.containsKey('data')) {
                    for (Object obj : (List<Object>) rootMap.get('data')) {
                        actualBills.add((Map<String, Object>) obj);
                    }
                } else if (rootMap.containsKey('id')) {
                    actualBills.add(rootMap);
                }
            } else if (untypedResponse instanceof List<Object>) {
                List<Object> rootList = (List<Object>) untypedResponse;
                if (!rootList.isEmpty()) {
                    Map<String, Object> firstItem = (Map<String, Object>) rootList[0];
                    if (firstItem.containsKey('data')) {
                        for (Object obj : (List<Object>) firstItem.get('data')) {
                            actualBills.add((Map<String, Object>) obj);
                        }
                    } else {
                        for (Object obj : rootList) {
                            actualBills.add((Map<String, Object>) obj);
                        }
                    }
                }
            }

            // Find ONLY the FIRST bill that is PENDING and in the future
            String targetBillId = null;
            Map<String, Object> targetBill = null;
            Date todayDate = Date.today();

            for (Map<String, Object> bill : actualBills) {
                String status = (String) bill.get('status');
                String billDateStr = (String) bill.get('billDate');
                
                if (status == 'PENDING' && String.isNotBlank(billDateStr)) {
                    Date bDate = Date.valueOf(billDateStr);
                    if (bDate > todayDate) {
                        targetBillId = (String) bill.get('id');
                        targetBill = bill;
                        break; 
                    }
                }
            }

            if (targetBillId == null) {
                System.debug('No future pending bills found.');
                return '[]';
            }

            // CALL THE HELPER METHOD: Fetch the line items for this bill
            String lineItemsJson = recalculateAndFetchLineItemHelper(targetBillId);
            System.debug('Line Items JSON:=====================> ' + lineItemsJson);
            if (String.isNotBlank(usageEntitlementAccountId) && String.isNotBlank(lineItemsJson)) {
                M3ter_UsageAllocator.allocateUsageAsync(usageEntitlementAccountId, lineItemsJson);
            }
            // Attach the raw line items directly to our target bill
            targetBill.put('fetchedLineItems', JSON.deserializeUntyped(lineItemsJson));

            // Return the fully assembled bill
            List<Map<String, Object>> finalResult = new List<Map<String, Object>>{ targetBill };
            System.debug('Final Result:=====================> ' + JSON.serialize(finalResult));
            return JSON.serialize(finalResult);

        } catch (Exception e) {
            System.debug('Error in listBills: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }
    }

    // METHOD 2: Used by your Second Experience Cloud Page
    @AuraEnabled
    public static String recalculateAndFetchLineItem(String billId, String usageEntitlementAccountId) {
        try {
            // Simply pass the billId to the helper method and return the result
            String lineItemsJson = recalculateAndFetchLineItemHelper(billId);
            if (String.isNotBlank(usageEntitlementAccountId) && String.isNotBlank(lineItemsJson)) {
                M3ter_UsageAllocator.allocateUsageAsync(usageEntitlementAccountId, lineItemsJson);
            }
            System.debug('Line Items JSON:=====================> ' + lineItemsJson);
            return lineItemsJson;
        } catch (Exception e) {
            System.debug('Error in recalculateAndFetchLineItem: ' + e.getMessage());
            throw new AuraHandledException(e.getMessage());
        }
    }

    // METHOD 3: The Private Helper (Does the actual heavy lifting)
    private static String recalculateAndFetchLineItemHelper(String billId) {
        // STEP 1: Recalculate
        HttpCalloutService recalcService = new HTTPCalloutService('M3ter_Recalculate'); 
        Map<String, Object> bodyMap = new Map<String, Object>();
        bodyMap.put('billIds', new List<String>{ billId }); 
        recalcService.setRequestBody(JSON.serialize(bodyMap));
        
        HttpResponse recalcResponse = recalcService.sendRequest();
        
        // Check Status Code for Recalculate (Allowing 2xx success codes)
        if (recalcResponse.getStatusCode() >= 300) {
            throw new CalloutException('Recalculate API failed. Status: ' + recalcResponse.getStatusCode() + ' Body: ' + recalcResponse.getBody());
        }

        Long startTime = System.now().getTime();
        Long delayInMilliseconds = 500; // 2000 ms = 2 second
        
        while (System.now().getTime() - startTime < delayInMilliseconds) {
            // Do nothing. Just burn a tiny bit of CPU time until 1 second passes.
        }

        // STEP 2: Fetch Line Items
        HttpCalloutService lineItemService = new HTTPCalloutService('M3ter_FetchLineItem');
        String url = lineItemService.getEndpointURL();
        lineItemService.setEndpointURL(url.replace('{billId}', billId));
        
        HttpResponse liResponse = lineItemService.sendRequest();
        
        if (liResponse.getStatusCode() != 200) {
            throw new CalloutException('FetchLineItem API failed. Status: ' + liResponse.getStatusCode() + ' Body: ' + liResponse.getBody());
        }
        
        // Return the raw JSON string of the line items
        return liResponse.getBody();
    }

   

}