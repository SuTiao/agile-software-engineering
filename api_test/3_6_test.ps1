# Room Booking API 测试脚本

# API 根路径
$baseUrl = "http://localhost:8080/api"
$outputFolder = "./test-results"

# 创建输出文件夹
if (!(Test-Path -Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

# 通用的 API 调用函数
function Invoke-ApiRequest {
    param (
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null,
        [string]$TestName
    )
    
    $uri = "$baseUrl$Endpoint"
    $headers = @{
        "Content-Type" = "application/json"
        "Accept" = "application/json"
    }
    
    Write-Host "执行测试: $TestName" -ForegroundColor Cyan
    Write-Host "$Method $uri" -ForegroundColor Gray
    
    $params = @{
        Method = $Method
        Uri = $uri
        Headers = $headers
    }
    
    if ($Body -and $Method -ne "GET") {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        $params.Add("Body", $jsonBody)
        Write-Host "请求体: $jsonBody" -ForegroundColor Gray
    }
    
    try {
        $response = Invoke-RestMethod @params
        Write-Host "状态: 成功" -ForegroundColor Green
        $response | ConvertTo-Json -Depth 10 | Out-File -FilePath "$outputFolder/$TestName.json"
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $statusDesc = $_.Exception.Response.StatusDescription
        $errorDetails = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { "No details available" }
        
        Write-Host "状态: 失败 ($statusCode $statusDesc)" -ForegroundColor Red
        Write-Host "错误: $errorDetails" -ForegroundColor Red
        
        # 保存错误信息
        @{
            StatusCode = $statusCode
            Error = $errorDetails
        } | ConvertTo-Json | Out-File -FilePath "$outputFolder/$TestName-error.json"
        
        return $null
    }
    finally {
        Write-Host "`n"
    }
}

Write-Host "开始 Room Booking API 测试..." -ForegroundColor Yellow

# 1. 测试获取所有房间
$rooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms" -TestName "get-all-rooms"

# 2. 测试获取可用房间
$availableRooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/available" -TestName "get-available-rooms"

# 3. 测试获取特定房间
if ($rooms -and $rooms.Count -gt 0) {
    $roomId = $rooms[0].id
    $room = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/$roomId" -TestName "get-room-by-id"
}

# 4. 测试获取所有用户
$users = Invoke-ApiRequest -Method "GET" -Endpoint "/users" -TestName "get-all-users"

# 5. 测试预订创建
if ($rooms -and $rooms.Count -gt 0 -and $users -and $users.Count -gt 0) {
    $roomId = $rooms[0].id
    $userId = $users[0].id
    
    $bookingData = @{
        user = @{ id = $userId }
        room = @{ id = $roomId }
        startTime = (Get-Date).AddDays(1).ToString("yyyy-MM-ddTHH:mm:ss")
        endTime = (Get-Date).AddDays(1).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
        conflictDetected = $false
    }
    
    $newBooking = Invoke-ApiRequest -Method "POST" -Endpoint "/bookings" -Body $bookingData -TestName "create-booking"
    
    # 6. 测试获取预订
    if ($newBooking) {
        $bookingId = $newBooking.id
        $booking = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/$bookingId" -TestName "get-booking-by-id"
        
        # 7. 测试取消预订
        Invoke-ApiRequest -Method "PATCH" -Endpoint "/bookings/$bookingId/cancel" -TestName "cancel-booking"
    }
}

# 8. 测试角色列表
$roles = Invoke-ApiRequest -Method "GET" -Endpoint "/roles" -TestName "get-all-roles"

# 9. 测试权限列表
$permissions = Invoke-ApiRequest -Method "GET" -Endpoint "/permissions" -TestName "get-all-permissions"

Write-Host "API 测试完成!" -ForegroundColor Yellow
Write-Host "结果保存在 $outputFolder 目录中" -ForegroundColor Yellow