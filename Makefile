.PHONY: up down logs test backend-test mobile-check mobile android web
up:
	docker compose up -d --build --wait
down:
	docker compose down
logs:
	docker compose logs -f api
test: backend-test mobile-check
backend-test:
	./scripts/test-backend.sh
mobile-check:
	cd mobile && flutter analyze && flutter test
mobile:
	cd mobile && flutter run
android:
	cd mobile && flutter build apk --debug
web:
	cd mobile && flutter run -d chrome --web-port 3000
