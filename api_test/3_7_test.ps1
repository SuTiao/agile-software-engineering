# Room Booking API 测试脚本 - 专为 Clash 代理环境优化
# 作者：GitHub Copilot
# 日期：2025年3月7日

# 配置参数
$baseUrl = "http://localhost:8080/api"  # 使用 127.0.0.1 而非 localhost 以避免可能的 DNS 解析问题
$outputFolder = "./test-results"
$connectionTimeoutSec = 10
$maxRetries = 3

# 创建输出文件夹
if (!(Test-Path -Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
    Write-Host "创建测试结果目录: $outputFolder" -ForegroundColor Gray
}

# 代理处理函数 - 专门针对 Clash 配置
function Set-ProxyBypass {
    # 保存系统代理设置
    $originalProxySettings = @{
        WebProxy = [System.Net.WebRequest]::DefaultWebProxy
        ProxyEnable = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyEnable
        ProxyServer = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings').ProxyServer
    }

    try {
        # 禁用系统级代理
        [System.Net.WebRequest]::DefaultWebProxy = $null
        # 设置环境变量绕过代理
        $Env:NO_PROXY = "localhost,127.0.0.1,::1"
        $Env:no_proxy = "localhost,127.0.0.1,::1"
        $Env:HTTP_PROXY = ""
        $Env:HTTPS_PROXY = ""
        $Env:http_proxy = ""
        $Env:https_proxy = ""

        Write-Host "已禁用系统代理并设置本地代理绕过" -ForegroundColor Gray
        
        return $originalProxySettings
    }
    catch {
        Write-Host "无法完全禁用代理: $_" -ForegroundColor Yellow
        return $originalProxySettings
    }
}

# 还原代理设置
function Restore-ProxySettings {
    param (
        $OriginalSettings
    )
    
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $OriginalSettings.WebProxy
        
        # 清除代理环境变量
        Remove-Item Env:NO_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:no_proxy -ErrorAction SilentlyContinue
        Remove-Item Env:HTTP_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:HTTPS_PROXY -ErrorAction SilentlyContinue
        Remove-Item Env:http_proxy -ErrorAction SilentlyContinue
        Remove-Item Env:https_proxy -ErrorAction SilentlyContinue
        
        Write-Host "已还原原始代理设置" -ForegroundColor Gray
    }
    catch {
        Write-Host "还原代理设置失败: $_" -ForegroundColor Yellow
    }
}

# 服务器健康检查函数
function Test-ServerConnection {
    param (
        [int]$RetryCount = 0
    )
    
    try {
        $ProgressPreference = 'SilentlyContinue'  # 禁用进度条以提高性能
        
        # 创建直接连接的 WebClient，绕过所有代理
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $handler.DefaultProxyCredentials = $null
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(2)
        
        # 发送请求
        $task = $client.GetAsync("$baseUrl/rooms")
        $task.Wait()
        $response = $task.Result
        
        # 检查响应状态
        if ($response.IsSuccessStatusCode) {
            Write-Host "服务器连接正常，状态码: $($response.StatusCode)" -ForegroundColor Green
            $client.Dispose()
            return $true
        } else {
            Write-Host "服务器返回错误状态码: $($response.StatusCode)" -ForegroundColor Yellow
            $client.Dispose()
            
            if ($RetryCount -lt $maxRetries) {
                Write-Host "将在 3 秒后重试 (尝试 $($RetryCount + 1)/$maxRetries)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 3
                return Test-ServerConnection -RetryCount ($RetryCount + 1)
            }
            return $false
        }
    } 
    catch {
        if ($RetryCount -lt $maxRetries) {
            Write-Host "服务器连接失败: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "将在 3 秒后重试 (尝试 $($RetryCount + 1)/$maxRetries)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
            return Test-ServerConnection -RetryCount ($RetryCount + 1)
        }
        Write-Host "服务器连接失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    finally {
        $ProgressPreference = 'Continue'  # 恢复进度条设置
    }
}

# 通用的 API 调用函数 - 直接连接版本
function Invoke-DirectApiRequest {
    param (
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null,
        [string]$TestName,
        [switch]$SkipOnFailure = $false
    )
    
    $uri = "$baseUrl$Endpoint"
    $headers = @{
        "Content-Type" = "application/json"
        "Accept" = "application/json"
        "X-Test-Name" = $TestName
    }
    
    Write-Host "`n执行测试: $TestName" -ForegroundColor Cyan
    Write-Host "$Method $uri" -ForegroundColor Gray
    
    try {
        # 创建直接连接的 HttpClient
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($connectionTimeoutSec)
        
        # 添加请求头
        foreach ($key in $headers.Keys) {
            $client.DefaultRequestHeaders.Add($key, $headers[$key])
        }
        
        # 准备请求
        $request = $null
        $content = $null
        
        if ($Body -and $Method -ne "GET") {
            $jsonBody = $Body | ConvertTo-Json -Depth 10
            Write-Host "请求体: $jsonBody" -ForegroundColor Gray
            $content = New-Object System.Net.Http.StringContent($jsonBody, [System.Text.Encoding]::UTF8, "application/json")
        }
        
        # 执行请求
        $response = $null
        switch ($Method) {
            "GET" { 
                $task = $client.GetAsync($uri)
                $task.Wait()
                $response = $task.Result
            }
            "POST" { 
                $task = $client.PostAsync($uri, $content)
                $task.Wait()
                $response = $task.Result
            }
            "PUT" { 
                $task = $client.PutAsync($uri, $content)
                $task.Wait()
                $response = $task.Result
            }
            "PATCH" {
                # HttpClient 没有 PatchAsync 方法，需要创建自定义请求
                $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Patch, $uri)
                if ($content) { $request.Content = $content }
                $task = $client.SendAsync($request)
                $task.Wait()
                $response = $task.Result
            }
            "DELETE" { 
                $task = $client.DeleteAsync($uri)
                $task.Wait()
                $response = $task.Result
            }
            default { throw "不支持的 HTTP 方法: $Method" }
        }
        
        # 处理响应
        if ($response.IsSuccessStatusCode) {
            $responseContent = $response.Content.ReadAsStringAsync().Result
            $result = $responseContent | ConvertFrom-Json
            
            Write-Host "状态: 成功 (状态码: $($response.StatusCode))" -ForegroundColor Green
            $responseContent | Out-File -FilePath "$outputFolder/$TestName.json" -Encoding utf8
            Write-Host "结果已保存至: $outputFolder/$TestName.json" -ForegroundColor Gray
            
            # 释放资源
            if ($request) { $request.Dispose() }
            if ($content) { $content.Dispose() }
            $response.Dispose()
            $client.Dispose()
            
            return $result
        } else {
            $errorContent = $response.Content.ReadAsStringAsync().Result
            $statusCode = [int]$response.StatusCode
            
            Write-Host "状态: 失败 (状态码: $statusCode)" -ForegroundColor Red
            Write-Host "错误: $errorContent" -ForegroundColor Red
            
            # 保存错误信息
            @{
                StatusCode = $statusCode
                Error = $errorContent
                Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            } | ConvertTo-Json | Out-File -FilePath "$outputFolder/$TestName-error.json" -Encoding utf8
            
            # 释放资源
            if ($request) { $request.Dispose() }
            if ($content) { $content.Dispose() }
            $response.Dispose()
            $client.Dispose()
            
            if ($SkipOnFailure) {
                Write-Host "测试标记为 SkipOnFailure，继续执行后续测试..." -ForegroundColor Yellow
                return $null
            } else {
                throw "API 测试失败: $errorContent (状态码: $statusCode)"
            }
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        Write-Host "请求失败: $errorMessage" -ForegroundColor Red
        
        # 保存错误信息
        @{
            Error = $errorMessage
            Exception = $_.Exception.GetType().Name
            Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            StackTrace = $_.ScriptStackTrace
        } | ConvertTo-Json | Out-File -FilePath "$outputFolder/$TestName-error.json" -Encoding utf8
        
        if ($SkipOnFailure) {
            Write-Host "测试标记为 SkipOnFailure，继续执行后续测试..." -ForegroundColor Yellow
            return $null
        } else {
            throw "API 请求失败: $errorMessage"
        }
    }
}

# 主函数 - 测试执行逻辑
function Start-ApiTest {
    # 应用代理绕过设置
    $originalProxySettings = Set-ProxyBypass
    
    try {
        Write-Host "=================== Room Booking API 测试 ===================" -ForegroundColor Yellow
        Write-Host "API 根路径: $baseUrl" -ForegroundColor Yellow
        Write-Host "测试结果目录: $outputFolder" -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "检查服务器连接..."
        
        if (-not (Test-ServerConnection)) {
            Write-Host "服务器连接失败，无法进行测试。请确保 Spring Boot 应用已启动。" -ForegroundColor Red
            Write-Host "检查事项:" -ForegroundColor Yellow
            Write-Host " 1. 确认后端应用运行在端口 8081" -ForegroundColor Yellow
            Write-Host " 2. 检查防火墙设置是否阻止了本地连接" -ForegroundColor Yellow
            Write-Host " 3. 尝试在浏览器中访问 http://127.0.0.1:8081/api/rooms 测试连通性" -ForegroundColor Yellow
            return
        }

        # 模块 1: 房间管理 API 测试
        Write-Host "`n模块 1: 房间管理 API 测试" -ForegroundColor Magenta
        $rooms = Invoke-DirectApiRequest -Method "GET" -Endpoint "/rooms" -TestName "get-all-rooms" -SkipOnFailure
        $availableRooms = Invoke-DirectApiRequest -Method "GET" -Endpoint "/rooms/available" -TestName "get-available-rooms" -SkipOnFailure
        
        if ($rooms -and $rooms.Count -gt 0) {
            $roomId = $rooms[0].id
            $room = Invoke-DirectApiRequest -Method "GET" -Endpoint "/rooms/$roomId" -TestName "get-room-by-id" -SkipOnFailure
            
            # 测试按容量查询房间
            Invoke-DirectApiRequest -Method "GET" -Endpoint "/rooms/capacity/10" -TestName "get-rooms-by-capacity" -SkipOnFailure
        } else {
            Write-Host "跳过单个房间相关测试，未找到可用房间" -ForegroundColor Yellow
        }

        # 模块 2: 用户管理 API 测试
        Write-Host "`n模块 2: 用户管理 API 测试" -ForegroundColor Magenta
        $users = Invoke-DirectApiRequest -Method "GET" -Endpoint "/users" -TestName "get-all-users" -SkipOnFailure
        
        if ($users -and $users.Count -gt 0) {
            $userId = $users[0].id
            Invoke-DirectApiRequest -Method "GET" -Endpoint "/users/$userId" -TestName "get-user-by-id" -SkipOnFailure
        } else {
            Write-Host "跳过单个用户相关测试，未找到用户" -ForegroundColor Yellow
        }

        # 其他模块测试代码保持不变...
        # 模块 3: 预订管理 API 测试
        Write-Host "`n模块 3: 预订管理 API 测试" -ForegroundColor Magenta
        if ($rooms -and $rooms.Count -gt 0 -and $users -and $users.Count -gt 0) {
            $roomId = $rooms[0].id
            $userId = $users[0].id
            
            $bookingData = @{
                user = @{ id = $userId }
                room = @{ id = $roomId }
                startTime = (Get-Date).AddDays(1).ToString("yyyy-MM-ddTHH:mm:ss")
                endTime = (Get-Date).AddDays(1).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ss")
                conflictDetected = $false
                status = "pending"  # 添加状态字段
            }
            
            $newBooking = Invoke-DirectApiRequest -Method "POST" -Endpoint "/bookings" -Body $bookingData -TestName "create-booking" -SkipOnFailure
            
            if ($newBooking) {
                $bookingId = $newBooking.id
                Invoke-DirectApiRequest -Method "GET" -Endpoint "/bookings" -TestName "get-all-bookings" -SkipOnFailure
                Invoke-DirectApiRequest -Method "GET" -Endpoint "/bookings/$bookingId" -TestName "get-booking-by-id" -SkipOnFailure
                Invoke-DirectApiRequest -Method "GET" -Endpoint "/bookings/user/$userId" -TestName "get-user-bookings" -SkipOnFailure
                Invoke-DirectApiRequest -Method "GET" -Endpoint "/bookings/room/$roomId" -TestName "get-room-bookings" -SkipOnFailure
                Invoke-DirectApiRequest -Method "PATCH" -Endpoint "/bookings/$bookingId/approve" -TestName "approve-booking" -SkipOnFailure
                Invoke-DirectApiRequest -Method "PATCH" -Endpoint "/bookings/$bookingId/cancel" -TestName "cancel-booking" -SkipOnFailure
            } else {
                Write-Host "跳过预订相关测试，创建预订失败" -ForegroundColor Yellow
            }
        } else {
            Write-Host "跳过预订相关测试，未找到可用房间或用户" -ForegroundColor Yellow
        }

        # 模块 4: 角色与权限 API 测试
        Write-Host "`n模块 4: 角色与权限 API 测试" -ForegroundColor Magenta
        $roles = Invoke-DirectApiRequest -Method "GET" -Endpoint "/roles" -TestName "get-all-roles" -SkipOnFailure
        $permissions = Invoke-DirectApiRequest -Method "GET" -Endpoint "/permissions" -TestName "get-all-permissions" -SkipOnFailure
        
        if ($roles -and $roles.Count -gt 0) {
            $roleId = $roles[0].id
            Invoke-DirectApiRequest -Method "GET" -Endpoint "/roles/$roleId" -TestName "get-role-by-id" -SkipOnFailure
        }
        
        if ($permissions -and $permissions.Count -gt 0) {
            $permissionId = $permissions[0].id
            Invoke-DirectApiRequest -Method "GET" -Endpoint "/permissions/$permissionId" -TestName "get-permission-by-id" -SkipOnFailure
        }
        
        # 模块 5: 通知 API 测试
        Write-Host "`n模块 5: 通知 API 测试" -ForegroundColor Magenta
        Invoke-DirectApiRequest -Method "GET" -Endpoint "/notifications" -TestName "get-all-notifications" -SkipOnFailure
        Invoke-DirectApiRequest -Method "GET" -Endpoint "/notifications/pending" -TestName "get-pending-notifications" -SkipOnFailure
        
        Write-Host "`n================== API 测试完成 ===================" -ForegroundColor Green
        Write-Host "测试结果已保存在 $outputFolder 目录中" -ForegroundColor Green
    }
    catch {
        Write-Host "测试过程中发生错误: $_" -ForegroundColor Red
    }
    finally {
        # 恢复原始代理设置
        Restore-ProxySettings -OriginalSettings $originalProxySettings
    }
}

# 执行测试
Start-ApiTest