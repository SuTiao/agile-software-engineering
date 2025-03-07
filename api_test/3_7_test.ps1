# Room Booking API 全面测试脚本 - 绕过代理版本
# 日期：2025年3月7日

# 保存原始代理设置
$originalProxySettings = @{
    HTTP_PROXY = $env:HTTP_PROXY
    HTTPS_PROXY = $env:HTTPS_PROXY
    NO_PROXY = $env:NO_PROXY
}

# 禁用系统代理
function Disable-SystemProxy {
    Write-Host "临时禁用系统代理..." -ForegroundColor Yellow
    $env:HTTP_PROXY = ""
    $env:HTTPS_PROXY = ""
    $env:NO_PROXY = "localhost,127.0.0.1,::1"
    
    # 尝试设置 WebRequest 默认代理为空
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $null
    } catch {
        Write-Host "无法设置 DefaultWebProxy: $_" -ForegroundColor Yellow
    }
}

# 恢复原始代理设置
function Restore-SystemProxy {
    Write-Host "恢复系统代理设置..." -ForegroundColor Yellow
    $env:HTTP_PROXY = $originalProxySettings.HTTP_PROXY
    $env:HTTPS_PROXY = $originalProxySettings.HTTPS_PROXY
    $env:NO_PROXY = $originalProxySettings.NO_PROXY
}

# 禁用代理
Disable-SystemProxy

# API 根路径 (使用IP而非localhost以避免DNS解析问题)
$baseUrl = "http://127.0.0.1:8080/api"
$outputFolder = "./test-results"

# 创建输出文件夹
if (!(Test-Path -Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
    Write-Host "创建测试结果目录: $outputFolder" -ForegroundColor Gray
}

# 设置TLS安全协议
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls

# TCP连接测试函数
function Test-TcpConnection {
    param (
        [string]$Uri,
        [int]$Timeout = 2000
    )
    
    Write-Host "正在测试与 $Uri 的TCP连接..." -ForegroundColor Yellow
    
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $uri = [System.Uri]$Uri
        $asyncResult = $tcpClient.BeginConnect($uri.Host, $uri.Port, $null, $null)
        $wait = $asyncResult.AsyncWaitHandle.WaitOne($Timeout)
        
        if ($wait) {
            Write-Host "TCP连接成功!" -ForegroundColor Green
            $tcpClient.EndConnect($asyncResult)
            $tcpClient.Close()
            return $true
        } else {
            Write-Host "TCP连接失败(超时)!" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "TCP连接错误: $_" -ForegroundColor Red
        return $false
    }
}

# HTTP服务器测试函数
function Test-ApiConnection {
    param (
        [string]$Endpoint = "/test/ping",
        [int]$RetryCount = 3,
        [int]$RetryDelay = 2
    )
    
    Write-Host "测试API服务器连通性..." -ForegroundColor Yellow
    $uri = "$baseUrl$Endpoint"
    
    for ($retry = 0; $retry -lt $RetryCount; $retry++) {
        if ($retry -gt 0) {
            Write-Host "尝试 #$($retry+1) (等待 ${RetryDelay}秒)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelay
        }
        
        try {
            # 创建直接连接的客户端以绕过代理
            $handler = New-Object System.Net.Http.HttpClientHandler
            $handler.UseProxy = $false
            $client = New-Object System.Net.Http.HttpClient($handler)
            $client.Timeout = [TimeSpan]::FromSeconds(5)
            
            # 尝试简单的GET请求
            $task = $client.GetAsync($uri)
            $task.Wait()
            $response = $task.Result
            
            if ($response.IsSuccessStatusCode) {
                $content = $response.Content.ReadAsStringAsync().Result
                Write-Host "API服务器响应正常! 状态码: $($response.StatusCode)" -ForegroundColor Green
                Write-Host "响应内容: $content" -ForegroundColor Green
                $client.Dispose()
                return $true
            } else {
                Write-Host "API服务器返回错误状态码: $($response.StatusCode)" -ForegroundColor Yellow
                $client.Dispose()
            }
        } catch {
            Write-Host "API连接错误: $_" -ForegroundColor Red
        }
    }
    
    Write-Host "无法连接到API服务器，请检查服务是否运行！" -ForegroundColor Red
    return $false
}

# 通用的 API 调用函数
function Invoke-ApiRequest {
    param (
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null,
        [string]$TestName,
        [int]$RetryCount = 2,
        [switch]$SkipOnFailure
    )
    
    $uri = "$baseUrl$Endpoint"
    
    Write-Host "执行测试: $TestName" -ForegroundColor Cyan
    Write-Host "$Method $uri" -ForegroundColor Gray
    
    # 尝试多种请求方式
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            if ($attempt -eq 0) {
                # 尝试 HttpClient (更可靠)
                $result = Invoke-HttpClientRequest -Method $Method -Uri $uri -Body $Body
            } elseif ($attempt -eq 1) {
                # 尝试 System.Net.WebClient
                $result = Invoke-WebClientRequest -Method $Method -Uri $uri -Body $Body
            } else {
                # 尝试 curl 命令
                $result = Invoke-CurlRequest -Method $Method -Uri $uri -Body $Body
            }
            
            if ($result) {
                Write-Host "状态: 成功" -ForegroundColor Green
                # 确保结果是字符串格式
                $resultStr = if ($result -is [string]) { $result } else { $result | ConvertTo-Json -Depth 10 }
                $resultStr | Out-File -FilePath "$outputFolder/$TestName.json" -Encoding utf8
                Write-Host "响应内容:" -ForegroundColor Green
                Write-Host $resultStr
                try {
                    if ($result -is [string]) {
                        return $result | ConvertFrom-Json
                    } else {
                        return $result
                    }
                } catch {
                    return $result
                }
            }
        } catch {
            $errorMsg = $_.Exception.Message
            Write-Host "尝试 #$($attempt+1) 失败: $errorMsg" -ForegroundColor Red
        }
    }
    
    Write-Host "状态: 所有尝试均失败" -ForegroundColor Red
    
    if ($SkipOnFailure) {
        Write-Host "跳过失败的测试: $TestName" -ForegroundColor Yellow
    } else {
        Write-Host "错误: 无法连接到API端点" -ForegroundColor Red
        # 保存错误信息
        @{
            Error = "无法连接到API端点"
            Method = $Method
            Endpoint = $Endpoint
            Time = Get-Date
        } | ConvertTo-Json | Out-File -FilePath "$outputFolder/$TestName-error.json"
    }
    
    return $null
}

function Invoke-HttpClientRequest {
    param (
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    
    Write-Host "使用 HttpClient 发送请求 (无代理)..." -ForegroundColor Gray
    
    # 创建自定义Http客户端以绕过代理
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.ServerCertificateCustomValidationCallback = {$true}
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    
    $client.DefaultRequestHeaders.Accept.Add("application/json")
    
    try {
        if ($Method -eq "GET") {
            $task = $client.GetStringAsync($Uri)
            $task.Wait()
            return $task.Result
        } else {
            $content = $null
            if ($Body) {
                $jsonBody = $Body | ConvertTo-Json -Depth 10
                $content = New-Object System.Net.Http.StringContent($jsonBody, [System.Text.Encoding]::UTF8, "application/json")
            } else {
                $content = New-Object System.Net.Http.StringContent("", [System.Text.Encoding]::UTF8, "application/json")
            }
            
            $response = $null
            $task = $null
            
            switch ($Method) {
                "POST" { 
                    $task = $client.PostAsync($Uri, $content)
                }
                "PUT" { 
                    $task = $client.PutAsync($Uri, $content)
                }
                "DELETE" { 
                    $task = $client.DeleteAsync($Uri)
                }
                "PATCH" { 
                    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Patch, $Uri)
                    if ($content) { $request.Content = $content }
                    $task = $client.SendAsync($request)
                }
                default { 
                    throw "不支持的HTTP方法: $Method" 
                }
            }
            
            $task.Wait()
            $response = $task.Result
            $response.EnsureSuccessStatusCode() | Out-Null
            $readTask = $response.Content.ReadAsStringAsync()
            $readTask.Wait()
            return $readTask.Result
        }
    } finally {
        if ($null -ne $content) { $content.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Invoke-WebClientRequest {
    param (
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    
    Write-Host "使用 WebClient 发送请求 (无代理)..." -ForegroundColor Gray
    $webClient = New-Object System.Net.WebClient
    
    # 绕过代理设置
    $webClient.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    
    $webClient.Headers.Add("Content-Type", "application/json")
    $webClient.Headers.Add("Accept", "application/json")
    
    try {
        if ($Method -eq "GET") {
            return $webClient.DownloadString($Uri)
        } else {
            $jsonBody = if ($Body) { $Body | ConvertTo-Json -Depth 10 } else { "{}" }
            return $webClient.UploadString($Uri, $Method, $jsonBody)
        }
    } finally {
        $webClient.Dispose()
    }
}

function Invoke-CurlRequest {
    param (
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    
    Write-Host "使用 curl 发送请求..." -ForegroundColor Gray
    $curlCommand = "curl -s -x """" -X $Method"  # -x "" 禁用代理
    $curlCommand += " -H 'Content-Type: application/json'"
    $curlCommand += " -H 'Accept: application/json'"
    
    if ($Body -and $Method -ne "GET") {
        $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
        # 转义JSON以便在命令行中使用
        $jsonBody = $jsonBody.Replace('"', '\"')
        $curlCommand += " -d `"$jsonBody`""
    }
    
    $curlCommand += " $Uri"
    
    try {
        return Invoke-Expression $curlCommand
    } catch {
        Write-Host "Curl请求失败: $_" -ForegroundColor Red
        return $null
    }
}

function Run-ApiTests {
    try {
        Write-Host "`n====== Room Booking API 全面测试 ======" -ForegroundColor Magenta
        Write-Host "开始时间: $(Get-Date)" -ForegroundColor Yellow
        Write-Host "API基础URL: $baseUrl" -ForegroundColor Yellow
        
        # 诊断信息
        Write-Host "`n=== 代理环境诊断 ===" -ForegroundColor Blue
        Write-Host "HTTP_PROXY: [$env:HTTP_PROXY]" -ForegroundColor Gray
        Write-Host "HTTPS_PROXY: [$env:HTTPS_PROXY]" -ForegroundColor Gray
        Write-Host "NO_PROXY: [$env:NO_PROXY]" -ForegroundColor Gray
        
        # TCP连接测试
        Write-Host "`n=== 第1步: 网络连接测试 ===" -ForegroundColor Blue
        $tcpConnected = Test-TcpConnection -Uri "$baseUrl/rooms"
        
        if (-not $tcpConnected) {
            Write-Host "TCP连接失败，请检查服务器是否运行及防火墙设置" -ForegroundColor Red
            Write-Host "尝试API连接测试以进一步诊断..." -ForegroundColor Yellow
        }
        
        # API可用性测试
        $apiAvailable = Test-ApiConnection -Endpoint "/rooms"
        if (-not $apiAvailable) {
            Write-Host "API连接测试失败，尝试使用测试端点..." -ForegroundColor Yellow
            $apiAvailable = Test-ApiConnection -Endpoint "/test/ping"
        }
        
        if (-not $apiAvailable) {
            Write-Host "无法连接到API服务器。请确保后端服务正在运行，并检查端口配置。" -ForegroundColor Red
            Write-Host "检查提示:" -ForegroundColor Yellow
            Write-Host " 1. Spring Boot应用是否已启动" -ForegroundColor Yellow
            Write-Host " 2. 应用是否正在监听端口8080" -ForegroundColor Yellow
            Write-Host " 3. 检查防火墙设置是否阻止了连接" -ForegroundColor Yellow
            return
        }
        
        # ===== 房间管理模块测试 =====
        Write-Host "`n=== 第2步: 房间管理模块测试 ===" -ForegroundColor Blue
        
        # 获取所有房间
        $rooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms" -TestName "get-all-rooms"
        
        if ($rooms -and $rooms.Count -gt 0) {
            Write-Host "成功获取房间列表，共 $($rooms.Count) 个房间" -ForegroundColor Green
            
            # 获取房间详情
            $roomId = $rooms[0].id
            Write-Host "使用第一个房间ID: $roomId 进行后续测试" -ForegroundColor Yellow
            $room = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/$roomId" -TestName "get-room-by-id"
            
            # 获取可用房间
            $availableRooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/available" -TestName "get-available-rooms"
            
            # 按容量筛选房间
            $capacity = 10
            $capacityRooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/capacity/$capacity" -TestName "get-rooms-by-capacity"
            
            # 创建新房间测试
            $newRoom = @{
                name = "测试会议室-$(Get-Random)"
                location = "3楼东侧"
                capacity = 15
                facilities = "投影仪, 白板, 视频会议"
                available = $true
                imageUrl = "https://example.com/room/image.jpg"
            }
            
            $createdRoom = Invoke-ApiRequest -Method "POST" -Endpoint "/rooms" -Body $newRoom -TestName "create-room"
            
            # 若创建成功，则更新房间
            if ($createdRoom) {
                $createdRoom.name = "已更新-$($createdRoom.name)"
                $createdRoom.capacity = 20
                $updatedRoom = Invoke-ApiRequest -Method "PUT" -Endpoint "/rooms/$($createdRoom.id)" -Body $createdRoom -TestName "update-room"
                
                # 删除测试房间
                $deleteResult = Invoke-ApiRequest -Method "DELETE" -Endpoint "/rooms/$($createdRoom.id)" -TestName "delete-room"
            }
            
            # 测试时间段可用房间查询
            $now = Get-Date
            $startTime = $now.AddDays(1).ToString("yyyy-MM-ddTHH:mm:ss")
            $endTime = $now.AddDays(1).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
            $availableRoomsBetween = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/available-between?start=$startTime&end=$endTime" -TestName "get-available-rooms-between"
        } else {
            Write-Host "未能获取房间数据，跳过对应的测试" -ForegroundColor Yellow
        }
        
        # ===== 用户管理模块测试 =====
        Write-Host "`n=== 第3步: 用户管理模块测试 ===" -ForegroundColor Blue
        
        # 获取所有用户
        $users = Invoke-ApiRequest -Method "GET" -Endpoint "/users" -TestName "get-all-users"
        
        if ($users -and $users.Count -gt 0) {
            Write-Host "成功获取用户列表，共 $($users.Count) 个用户" -ForegroundColor Green
            
            # 获取用户详情
            $userId = $users[0].id
            Write-Host "使用第一个用户ID: $userId 进行后续测试" -ForegroundColor Yellow
            $user = Invoke-ApiRequest -Method "GET" -Endpoint "/users/$userId" -TestName "get-user-by-id"
            
            # 如果用户有username属性，尝试通过用户名获取用户
            if ($user -and $user.username) {
                $userByUsername = Invoke-ApiRequest -Method "GET" -Endpoint "/users/username/$($user.username)" -TestName "get-user-by-username"
            }
            
            # 创建新用户测试
            $randomSuffix = Get-Random
            $newUser = @{
                username = "testuser$randomSuffix"
                email = "testuser$randomSuffix@example.com"
                firstName = "Test"
                lastName = "User"
                passwordHash = "password123" # 会在后端加密
                role = @{ id = 2 } # 假设ID=2是普通用户角色
            }
            
            $createdUser = Invoke-ApiRequest -Method "POST" -Endpoint "/users" -Body $newUser -TestName "create-user"
            
            # 若创建成功，则更新用户
            if ($createdUser) {
                $createdUser.firstName = "Updated"
                $createdUser.lastName = "TestUser"
                $updatedUser = Invoke-ApiRequest -Method "PUT" -Endpoint "/users/$($createdUser.id)" -Body $createdUser -TestName "update-user"
                
                # 删除测试用户
                $deleteResult = Invoke-ApiRequest -Method "DELETE" -Endpoint "/users/$($createdUser.id)" -TestName "delete-user"
            }
        } else {
            Write-Host "未能获取用户数据，跳过对应的测试" -ForegroundColor Yellow
        }
        
        # ===== 角色和权限模块测试 =====
        Write-Host "`n=== 第4步: 角色和权限模块测试 ===" -ForegroundColor Blue
        
        # 获取所有角色
        $roles = Invoke-ApiRequest -Method "GET" -Endpoint "/roles" -TestName "get-all-roles"
        
        # 获取所有权限
        $permissions = Invoke-ApiRequest -Method "GET" -Endpoint "/permissions" -TestName "get-all-permissions"
        
        if ($roles -and $roles.Count -gt 0) {
            # 获取角色详情
            $roleId = $roles[0].id
            $role = Invoke-ApiRequest -Method "GET" -Endpoint "/roles/$roleId" -TestName "get-role-by-id"
            
            # 如果角色有name属性，尝试通过名称获取角色
            if ($role -and $role.name) {
                $roleByName = Invoke-ApiRequest -Method "GET" -Endpoint "/roles/name/$($role.name)" -TestName "get-role-by-name"
            }
        }
        
        if ($permissions -and $permissions.Count -gt 0) {
            # 获取权限详情
            $permissionId = $permissions[0].id
            $permission = Invoke-ApiRequest -Method "GET" -Endpoint "/permissions/$permissionId" -TestName "get-permission-by-id"
            
            # 如果权限有name属性，尝试通过名称获取权限
            if ($permission -and $permission.name) {
                $permissionByName = Invoke-ApiRequest -Method "GET" -Endpoint "/permissions/name/$($permission.name)" -TestName "get-permission-by-name"
            }
        }
        
        # ===== 预订管理模块测试 =====
        Write-Host "`n=== 第5步: 预订管理模块测试 ===" -ForegroundColor Blue
        
        # 获取所有预订
        $bookings = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings" -TestName "get-all-bookings"
        
        if ($rooms -and $rooms.Count -gt 0 -and $users -and $users.Count -gt 0) {
            # 创建新预订
            $roomId = $rooms[0].id
            $userId = $users[0].id
            
            $startTime = (Get-Date).AddDays(1).ToString("yyyy-MM-ddTHH:mm:ss")
            $endTime = (Get-Date).AddDays(1).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
            
            $newBooking = @{
                user = @{ id = $userId }
                room = @{ id = $roomId }
                startTime = $startTime
                endTime = $endTime
                status = "pending"
                conflictDetected = $false
            }
            
            $createdBooking = Invoke-ApiRequest -Method "POST" -Endpoint "/bookings" -Body $newBooking -TestName "create-booking"
            
            if ($createdBooking) {
                # 获取预订详情
                $bookingId = $createdBooking.id
                $booking = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/$bookingId" -TestName "get-booking-by-id"
                
                # 更新预订
                if ($booking) {
                    $booking.startTime = (Get-Date).AddDays(2).ToString("yyyy-MM-ddTHH:mm:ss")
                    $booking.endTime = (Get-Date).AddDays(2).AddHours(3).ToString("yyyy-MM-ddTHH:mm:ss")
                    $updatedBooking = Invoke-ApiRequest -Method "PUT" -Endpoint "/bookings/$bookingId" -Body $booking -TestName "update-booking"
                }
                
                # 获取用户的预订
                $userBookings = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/user/$userId" -TestName "get-bookings-by-user"
                
                # 获取房间的预订
                $roomBookings = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/room/$roomId" -TestName "get-bookings-by-room"
                
                # 获取状态的预订
                $pendingBookings = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/status/pending" -TestName "get-bookings-by-status"
                
                # 获取用户未来的预订
                $futureBokings = Invoke-ApiRequest -Method "GET" -Endpoint "/bookings/user/$userId/future" -TestName "get-user-future-bookings"
                
                # 批准预订
                $approveResult = Invoke-ApiRequest -Method "PATCH" -Endpoint "/bookings/$bookingId/approve" -TestName "approve-booking"
                
                # 取消预订
                $cancelResult = Invoke-ApiRequest -Method "PATCH" -Endpoint "/bookings/$bookingId/cancel" -TestName "cancel-booking"
                
                # 删除预订
                $deleteResult = Invoke-ApiRequest -Method "DELETE" -Endpoint "/bookings/$bookingId" -TestName "delete-booking"
            }
        } else {
            Write-Host "缺少必要的房间或用户数据，跳过预订模块测试" -ForegroundColor Yellow
        }
        
        # ===== 通知模块测试 =====
        Write-Host "`n=== 第6步: 通知模块测试 ===" -ForegroundColor Blue
        
        # 获取所有通知
        $notifications = Invoke-ApiRequest -Method "GET" -Endpoint "/notifications" -TestName "get-all-notifications"
        
        if ($notifications -and $notifications.Count -gt 0) {
            # 获取通知详情
            $notificationId = $notifications[0].id
            $notification = Invoke-ApiRequest -Method "GET" -Endpoint "/notifications/$notificationId" -TestName "get-notification-by-id"
            
            # 如果通知有关联的预订，查询该预订的所有通知
            if ($notification -and $notification.booking -and $notification.booking.id) {
                $bookingId = $notification.booking.id
                $bookingNotifications = Invoke-ApiRequest -Method "GET" -Endpoint "/notifications/booking/$bookingId" -TestName "get-notifications-by-booking"
            }
            
            # 获取待处理的通知
            $pendingNotifications = Invoke-ApiRequest -Method "GET" -Endpoint "/notifications/pending" -TestName "get-pending-notifications"
            
            # 标记通知为已发送
            $markSentResult = Invoke-ApiRequest -Method "PATCH" -Endpoint "/notifications/$notificationId/mark-sent" -TestName "mark-notification-as-sent"
            
            # 标记通知为发送失败
            $markFailedResult = Invoke-ApiRequest -Method "PATCH" -Endpoint "/notifications/$notificationId/mark-failed" -TestName "mark-notification-as-failed"
            
            # 删除通知
            $deleteResult = Invoke-ApiRequest -Method "DELETE" -Endpoint "/notifications/$notificationId" -TestName "delete-notification"
        } else {
            Write-Host "未能获取通知数据，跳过通知模块详细测试" -ForegroundColor Yellow
        }
        
        Write-Host "`n====== 测试完成 ======" -ForegroundColor Magenta
        Write-Host "结束时间: $(Get-Date)" -ForegroundColor Yellow
        Write-Host "测试结果保存在 $outputFolder 目录中" -ForegroundColor Green
    }
    catch {
        Write-Host "`n[错误] 测试过程中发生异常:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    finally {
        # 始终恢复代理设置
        Restore-SystemProxy
    }
}

# 执行测试
Run-ApiTests