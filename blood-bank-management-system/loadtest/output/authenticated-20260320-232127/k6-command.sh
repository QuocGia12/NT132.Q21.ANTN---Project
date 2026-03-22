k6 run -e BASE_URL=http://blood-bank.com -e MODE=authenticated -e LOGIN_EMAIL=nguyengia595@gmail.com -e LOGIN_PASSWORD=12345678 -e VUS=10 -e DURATION=2m -e THINK_TIME=1 loadtest/k6-webapp.js 
