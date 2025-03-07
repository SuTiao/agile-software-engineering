# Room Booking API 测试脚本 - 绕过代理版

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

# API 根路径 (使用IP而非localhost)
$baseUrl = "http://127.0.0.1:8080/api"
$outputFolder = "./test-results"

# 创建输出文件夹
if (!(Test-Path -Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

# 设置TLS安全协议
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12, [Net.SecurityProtocolType]::Tls11, [Net.SecurityProtocolType]::Tls

# 诊断函数
function Test-Connection {
    param ($Uri)
    
    Write-Host "正在测试与 $Uri 的连接..." -ForegroundColor Yellow
    
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $uri = [System.Uri]$Uri
        $asyncResult = $tcpClient.BeginConnect($uri.Host, $uri.Port, $null, $null)
        $wait = $asyncResult.AsyncWaitHandle.WaitOne(1000)
        
        if ($wait) {
            Write-Host "TCP连接成功!" -ForegroundColor Green
            $tcpClient.EndConnect($asyncResult)
            $tcpClient.Close()
            return $true
        } else {
            Write-Host "TCP连接失败!" -ForegroundColor Red
            return $false
        }
    } catch {
        Write-Host "TCP连接错误: $_" -ForegroundColor Red
        return $false
    }
}

# 通用的 API 调用函数
function Invoke-ApiRequest {
    param (
        [string]$Method,
        [string]$Endpoint,
        [object]$Body = $null,
        [string]$TestName,
        [int]$RetryCount = 2
    )
    
    $uri = "$baseUrl$Endpoint"
    
    Write-Host "执行测试: $TestName" -ForegroundColor Cyan
    Write-Host "$Method $uri" -ForegroundColor Gray
    
    # 尝试多种请求方式
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            if ($attempt -eq 0) {
                # 尝试 Invoke-RestMethod (更可靠)
                $result = Invoke-RestMethodWithoutProxy -Method $Method -Uri $uri -Body $Body
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
                $resultStr | Out-File -FilePath "$outputFolder/$TestName.json"
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
    Write-Host "错误: 无法连接到API端点" -ForegroundColor Red
    
    # 保存错误信息
    @{
        Error = "无法连接到API端点"
    } | ConvertTo-Json | Out-File -FilePath "$outputFolder/$TestName-error.json"
    
    return $null
}

function Invoke-RestMethodWithoutProxy {
    param (
        [string]$Method,
        [string]$Uri,
        [object]$Body = $null
    )
    
    Write-Host "使用 Invoke-RestMethod 发送请求 (无代理)..." -ForegroundColor Gray
    
    $headers = @{
        "Content-Type" = "application/json"
        "Accept" = "application/json"
    }
    
    # 创建自定义WebClient以绕过代理
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $handler.ServerCertificateCustomValidationCallback = {$true}
    $client = New-Object System.Net.Http.HttpClient($handler)
    
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
            
            $task = switch ($Method) {
                "POST" { $client.PostAsync($Uri, $content) }
                "PUT" { $client.PutAsync($Uri, $content) }
                "DELETE" { $client.DeleteAsync($Uri) }
                "PATCH" { 
                    $method = New-Object System.Net.Http.HttpMethod("PATCH")
                    $request = New-Object System.Net.Http.HttpRequestMessage($method, $Uri)
                    $request.Content = $content
                    $client.SendAsync($request)
                }
                default { throw "不支持的HTTP方法: $Method" }
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
        $client.Dispose()
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
    
    if ($Method -eq "GET") {
        return $webClient.DownloadString($Uri)
    } else {
        $jsonBody = $Body | ConvertTo-Json -Depth 10
        return $webClient.UploadString($Uri, $Method, $jsonBody)
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
    
    return Invoke-Expression $curlCommand
}

try {
    Write-Host "开始 Room Booking API 测试..." -ForegroundColor Yellow

    # 输出诊断信息
    Write-Host "当前代理环境变量:" -ForegroundColor Yellow
    Write-Host "HTTP_PROXY: [$env:HTTP_PROXY]" -ForegroundColor Gray
    Write-Host "HTTPS_PROXY: [$env:HTTPS_PROXY]" -ForegroundColor Gray
    Write-Host "NO_PROXY: [$env:NO_PROXY]" -ForegroundColor Gray

    # 先测试连接是否可用
    Test-Connection "$baseUrl/rooms"

    # 1. 测试获取所有房间
    $rooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms" -TestName "get-all-rooms"

    # 如果得到了房间数据，不再执行其他测试
    if ($rooms) {
        Write-Host "成功获取房间数据! API 可以正常访问。" -ForegroundColor Green
        return
    }

    # 2. 测试获取可用房间
    $availableRooms = Invoke-ApiRequest -Method "GET" -Endpoint "/rooms/available" -TestName "get-available-rooms"

    # 3. 获取所有用户
    $users = Invoke-ApiRequest -Method "GET" -Endpoint "/users" -TestName "get-all-users"

    Write-Host "API 测试完成!" -ForegroundColor Yellow
    Write-Host "结果保存在 $outputFolder 目录中" -ForegroundColor Yellow
}
finally {
    # 始终恢复代理设置
    Restore-SystemProxy
}