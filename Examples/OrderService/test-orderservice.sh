#!/bin/bash
# OrderService integration test
# Tests the complete order lifecycle with proper state transitions

set -e

# Extract order ID from JSON response
extract_id() {
    echo "$1" | grep -o '"id":"[^"]*"' | cut -d'"' -f4
}

echo "=== OrderService Integration Test ==="
echo ""

# Test 1: Create order
echo "1. Creating order..."
ORDER_JSON=$(curl -s -X POST http://localhost:$PORT/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"cust-123","items":[{"productId":"prod-1","quantity":2,"price":29.99}]}')
ORDER_ID=$(extract_id "$ORDER_JSON")

if [ -z "$ORDER_ID" ]; then
    echo "ERROR: Failed to create order"
    echo "Response: $ORDER_JSON"
    exit 1
fi

echo "   Created order: $ORDER_ID"
echo "   Status: draft"

# Test 2: List all orders
echo ""
echo "2. Listing all orders..."
LIST_RESPONSE=$(curl -s http://localhost:$PORT/orders)
echo "   Found $(echo "$LIST_RESPONSE" | grep -o '"id"' | wc -l | tr -d ' ') order(s)"

# Test 3: Get specific order
echo ""
echo "3. Getting order by ID..."
GET_RESPONSE=$(curl -s "http://localhost:$PORT/orders/$ORDER_ID")
if echo "$GET_RESPONSE" | grep -q "$ORDER_ID"; then
    echo "   ✓ Order retrieved successfully"
else
    echo "   ✗ Failed to retrieve order"
    exit 1
fi

# Test 4: Place order (draft -> placed)
echo ""
echo "4. Placing order (draft → placed)..."
PLACE_RESPONSE=$(curl -s -X POST "http://localhost:$PORT/orders/$ORDER_ID/place")
if echo "$PLACE_RESPONSE" | grep -q '"status":"placed"'; then
    echo "   ✓ Order placed successfully"
else
    echo "   ✗ Failed to place order"
    echo "   Response: $PLACE_RESPONSE"
    exit 1
fi

# Test 5: Pay for order (placed -> paid)
echo ""
echo "5. Paying for order (placed → paid)..."
PAY_RESPONSE=$(curl -s -X POST "http://localhost:$PORT/orders/$ORDER_ID/pay" \
  -H "Content-Type: application/json" \
  -d '{"paymentMethod":"credit_card","amount":59.98}')
if echo "$PAY_RESPONSE" | grep -q '"status":"paid"'; then
    echo "   ✓ Payment processed successfully"
else
    echo "   ✗ Failed to process payment"
    echo "   Response: $PAY_RESPONSE"
    exit 1
fi

# Test 6: Ship order (paid -> shipped)
echo ""
echo "6. Shipping order (paid → shipped)..."
SHIP_RESPONSE=$(curl -s -X POST "http://localhost:$PORT/orders/$ORDER_ID/ship" \
  -H "Content-Type: application/json" \
  -d '{"carrier":"FedEx","trackingNumber":"TRACK-123"}')
if echo "$SHIP_RESPONSE" | grep -q '"status":"shipped"'; then
    echo "   ✓ Order shipped successfully"
else
    echo "   ✗ Failed to ship order"
    echo "   Response: $SHIP_RESPONSE"
    exit 1
fi

# Test 7: Deliver order (shipped -> delivered)
echo ""
echo "7. Delivering order (shipped → delivered)..."
DELIVER_RESPONSE=$(curl -s -X POST "http://localhost:$PORT/orders/$ORDER_ID/deliver")
if echo "$DELIVER_RESPONSE" | grep -q '"status":"delivered"'; then
    echo "   ✓ Order delivered successfully"
else
    echo "   ✗ Failed to deliver order"
    echo "   Response: $DELIVER_RESPONSE"
    exit 1
fi

# Test 8: Cancel a new draft order
echo ""
echo "8. Testing cancel operation..."
CANCEL_ORDER_JSON=$(curl -s -X POST http://localhost:$PORT/orders \
  -H "Content-Type: application/json" \
  -d '{"customerId":"cust-456","items":[{"productId":"prod-2","quantity":1,"price":19.99}]}')
CANCEL_ORDER_ID=$(extract_id "$CANCEL_ORDER_JSON")

if [ -n "$CANCEL_ORDER_ID" ]; then
    CANCEL_RESPONSE=$(curl -s -X POST "http://localhost:$PORT/orders/$CANCEL_ORDER_ID/cancel")
    if echo "$CANCEL_RESPONSE" | grep -q '"status":"cancelled"'; then
        echo "   ✓ Order cancelled successfully"
    else
        echo "   ✗ Failed to cancel order"
        echo "   Response: $CANCEL_RESPONSE"
        exit 1
    fi
else
    echo "   ✗ Failed to create order for cancellation test"
    exit 1
fi

echo ""
echo "=== All Tests Passed ==="
exit 0
