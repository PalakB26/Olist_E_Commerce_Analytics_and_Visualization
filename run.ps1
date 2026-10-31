$ErrorActionPreference = "Stop"
$db = "brazilian_e_commerce"
$env:PGPASSWORD = Read-Host "postgres password"

# 01 is allowed to fail if the database already exists
psql -U postgres -d postgres -f .\sql\01_create_database.sql

foreach ($s in "02_create_tables","04_load_data") {
  psql -U postgres -d $db -v ON_ERROR_STOP=1 -f ".\sql\$s.sql"
  if ($LASTEXITCODE -ne 0) { throw "$s failed" }
}
foreach ($s in "03_profiling","05_data_cleaning","06_business_questions","07_advanced_analysis","08_star_schema") {
  psql -U postgres -d $db -v ON_ERROR_STOP=1 -f ".\sql\$s.sql" -o ".\sql\${s}_output.txt"
  if ($LASTEXITCODE -ne 0) { throw "$s failed" }
}
Remove-Item Env:\PGPASSWORD
Write-Host "Pipeline complete."