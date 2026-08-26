package io.gatewaysmashes.rhcl.api;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;

@QuarkusTest
class AiV1ExtraResourceTest {

    @Test
    void completionsReturnsTextCompletion() {
        given()
                .contentType("application/json")
                .body("{\"model\":\"banking-mock-gpt\",\"prompt\":\"hello\"}")
                .when().post("/api/v1/completions")
                .then()
                .statusCode(200)
                .body("object", equalTo("text_completion"));
    }

    @Test
    void embeddingsReturnsList() {
        given()
                .contentType("application/json")
                .body("{\"model\":\"text-embedding-mock\",\"input\":\"hello\"}")
                .when().post("/api/v1/embeddings")
                .then()
                .statusCode(200)
                .body("object", equalTo("list"));
    }

    @Test
    void responsesReturnsResponseObject() {
        given()
                .contentType("application/json")
                .body("{\"model\":\"banking-mock-gpt\",\"input\":\"hello\"}")
                .when().post("/api/v1/responses")
                .then()
                .statusCode(200)
                .body("object", equalTo("response"));
    }
}
