package io.gatewaysmashes.rhcl.api;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.notNullValue;

@QuarkusTest
class BankingResourceTest {

    @Test
    void shouldReturnSummaryV1() {
        given()
                .when().get("/api/v1/accounts/summary")
                .then()
                .statusCode(200)
                .body("apiVersion", notNullValue())
                .body("banks", notNullValue())
                .body("grandTotal", notNullValue());
    }

    @Test
    void shouldReturnEchoResponse() {
        given()
                .header("x-test", "true")
                .when().get("/api/echo")
                .then()
                .statusCode(200)
                .body("method", notNullValue())
                .body("headers", notNullValue());
    }
}
