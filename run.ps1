$ErrorActionPreference = "Stop"
$db = "brazilian_e_commerce"
psql -U postgres -d postgres -f .\sql\01_create_database.sql
psql -U postgres -d $db -f .\sql\02_create_tables.sql
psql -U postgres -d $db -f .\sql\04_load_data.sql
foreach ($s in "03_profiling","05_data_cleaning","06_business_questions","07_advanced_analysis","08_star_schema") {
  psql -U postgres -d $db -v ON_ERROR_STOP=1 -f ".\sql\$s.sql" -o ".\sql\${s}_output.txt"
  if ($LASTEXITCODE -ne 0) { throw "$s failed" }
}
Write-Host "Pipeline complete."