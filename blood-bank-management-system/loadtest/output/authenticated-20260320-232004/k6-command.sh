k6 run -e BASE_URL=http://blood-bank.com -e MODE=authenticated -e LOGIN_EMAIL=suraj@admin.com -e LOGIN_PASSWORD=bbms@admin -e VUS=10 -e DURATION=2m -e THINK_TIME=1 loadtest/k6-webapp.js 
