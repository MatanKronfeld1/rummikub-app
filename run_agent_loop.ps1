# run_agent_loop.ps1
$tasksFile = "TASKS.md"
$maxIterations = 20
$i = 0

Write-Host "Starting autonomous execution loop..." -ForegroundColor Green

while ($i -lt $maxIterations) {
    # Check if there are remaining tasks
    $remainingTasks = Select-String -Path $tasksFile -Pattern "-\s*\[\s*\]"
    if (-not $remainingTasks) {
        Write-Host "All tasks completed in TASKS.md!" -ForegroundColor Green
        break
    }

    $i++
    Write-Host "--- Starting Iteration $i ---" -ForegroundColor Yellow

    # Run Claude Code CLI in headless mode with auto-permissions
    claude -p "1. Read TASKS.md and identify the FIRST unchecked task (- [ ]). 2. Implement ONLY that task. 3. Run the relevant pytest or flutter test. 4. If test passes, mark - [x] in TASKS.md. 5. Print a 2-line summary and exit." --dangerously-skip-permissions

    # Small delay between runs
    Start-Sleep -Seconds 3
}

Write-Host "Autonomous run finished." -ForegroundColor Green