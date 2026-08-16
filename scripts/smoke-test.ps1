param([ValidateSet('SUCCESS', 'FAILED')] [string]$PaymentStatus = 'SUCCESS')
$ErrorActionPreference = 'Stop'

$keycloakUrl = 'http://localhost:8080'
$catalogueUrl = 'http://localhost:8081'
$inventoryUrl = 'http://localhost:8082'
$orderUrl = 'http://localhost:8083'
$paymentUrl = 'http://localhost:8084'
$clientId = 'sparelink-api'

function Get-AccessToken([string]$username, [string]$password) {
    (Invoke-RestMethod -Method Post `
        -Uri "$keycloakUrl/realms/sparelink/protocol/openid-connect/token" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body "client_id=$clientId&grant_type=password&username=$username&password=$password"
    ).access_token
}

function Get-JwtSubject([string]$token) {
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
            ConvertFrom-Json).sub
}

foreach ($endpoint in @($catalogueUrl, $inventoryUrl, $orderUrl, $paymentUrl)) {
    $health = Invoke-RestMethod -Uri "$endpoint/actuator/health"
    if ($health.status -ne 'UP') {
        throw "Service at $endpoint is not healthy."
    }
}

$adminToken = Get-AccessToken 'admin' 'admin'
$customerToken = Get-AccessToken 'customer' 'customer'
$adminHeaders = @{ Authorization = "Bearer $adminToken" }
$customerHeaders = @{ Authorization = "Bearer $customerToken" }
$marker = [guid]::NewGuid().ToString('N').Substring(0, 8)
$brandId = [guid]::NewGuid()
$categoryId = [guid]::NewGuid()

Invoke-RestMethod -Method Post -Uri "$catalogueUrl/api/brands" -Headers $adminHeaders `
    -ContentType 'application/json' -Body (@{ id = $brandId; name = "Smoke Brand $marker" } | ConvertTo-Json) | Out-Null
Invoke-RestMethod -Method Post -Uri "$catalogueUrl/api/categories" -Headers $adminHeaders `
    -ContentType 'application/json' -Body (@{ id = $categoryId; name = "Smoke Category $marker"; parentId = $null } | ConvertTo-Json) | Out-Null

$part = Invoke-RestMethod -Method Post -Uri "$catalogueUrl/api/parts" -Headers $adminHeaders `
    -ContentType 'application/json' -Body (@{
        sku = "SMOKE-$marker"; name = 'Platform Smoke Part'; brandId = $brandId; categoryId = $categoryId
        price = @{ amount = 1999; currency = 'USD' }; status = 'ACTIVE'; vehicleFitments = @(); images = @()
    } | ConvertTo-Json -Depth 4)
$partId = $part.data.id

Invoke-RestMethod -Method Post -Uri "$inventoryUrl/api/inventory/stock?partId=$partId&quantity=5" `
    -Headers $adminHeaders | Out-Null

$customerId = Get-JwtSubject $customerToken
$order = Invoke-RestMethod -Method Post -Uri "$orderUrl/api/orders" -Headers $customerHeaders `
    -ContentType 'application/json' -Body (@{
        customerId = $customerId; items = @(@{ partId = $partId; quantity = 2 })
    } | ConvertTo-Json -Depth 4)

$deadline = (Get-Date).AddSeconds(30)
do {
    $available = Invoke-RestMethod -Uri "$inventoryUrl/api/inventory/stock/$partId" -Headers $customerHeaders
    if ($available -eq 3) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

if ($available -ne 3) {
    throw "Expected available stock 3 after reservation, but got $available."
}

$paymentDeadline = (Get-Date).AddSeconds(30)
do {
    $payments = Invoke-RestMethod -Uri "${paymentUrl}/api/payments/customer/${customerId}?size=10"
    $payment = $payments.content | Where-Object { $_.orderId -eq $order.orderId } | Select-Object -First 1
    if ($null -eq $payment) { Start-Sleep -Seconds 2 }
} while (($null -eq $payment) -and ((Get-Date) -lt $paymentDeadline))

if ($null -eq $payment) {
    throw "Payment Service did not create a payment for order $($order.orderId)."
}

Invoke-RestMethod -Method Patch -Uri "$paymentUrl/api/payments/$($payment.id)/status" `
    -ContentType 'application/json' -Body ("{`"status`":`"$PaymentStatus`"}") | Out-Null

$orderDeadline = (Get-Date).AddSeconds(30)
do {
    $updatedOrder = Invoke-RestMethod -Uri "$orderUrl/api/orders/$($order.orderId)" -Headers $customerHeaders
    $expectedOrderStatus = if ($PaymentStatus -eq 'SUCCESS') { 'PAID' } else { 'PAYMENT_FAILED' }
    if ($updatedOrder.status -eq $expectedOrderStatus) { break }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $orderDeadline)

if ($updatedOrder.status -ne $expectedOrderStatus) {
    throw "Expected order $($order.orderId) to be $expectedOrderStatus, but got $($updatedOrder.status)."
}

if ($PaymentStatus -eq 'FAILED') {
    $releaseDeadline = (Get-Date).AddSeconds(30)
    do {
        $available = Invoke-RestMethod -Uri "$inventoryUrl/api/inventory/stock/$partId" -Headers $customerHeaders
        if ($available -eq 5) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $releaseDeadline)
    if ($available -ne 5) { throw "Expected stock 5 after payment failure, but got $available." }
}

Write-Host "Platform smoke test passed: order $($order.orderId) reserved inventory (5 -> 3), created payment $($payment.id), and reached $expectedOrderStatus."
