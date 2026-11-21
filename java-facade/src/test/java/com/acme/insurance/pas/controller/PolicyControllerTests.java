package com.acme.insurance.pas.controller;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.test.context.junit4.SpringRunner;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.util.Base64Utils;

import java.nio.charset.StandardCharsets;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
import static org.hamcrest.Matchers.*;

@RunWith(SpringRunner.class)
@SpringBootTest
@AutoConfigureMockMvc
public class PolicyControllerTests {

    private static final String AUTH = basic("test-client", "test-secret");

    @Autowired
    private MockMvc mockMvc;

    private static String basic(String user, String password) {
        return "Basic " + Base64Utils.encodeToString(
                (user + ":" + password).getBytes(StandardCharsets.UTF_8));
    }

    @Test
    public void getPolicy_returnsPolicy() throws Exception {
        mockMvc.perform(get("/api/v1/policies/POL-00000001")
                .header(HttpHeaders.AUTHORIZATION, AUTH))
                .andExpect(status().isOk())
                .andExpect(content().contentType(MediaType.APPLICATION_JSON_UTF8))
                .andExpect(jsonPath("$.policyNumber", is("POL-00000001")))
                .andExpect(jsonPath("$.policyType", is("HOM")))
                .andExpect(jsonPath("$.policyStatus", is("AC")))
                .andExpect(jsonPath("$.totalPremium", is(1250.0)));
    }

    @Test
    public void getPolicy_notFound() throws Exception {
        mockMvc.perform(get("/api/v1/policies/NONEXISTENT")
                .header(HttpHeaders.AUTHORIZATION, AUTH))
                .andExpect(status().isNotFound());
    }

    @Test
    public void getCoverages_returnsCoverages() throws Exception {
        mockMvc.perform(get("/api/v1/policies/POL-00000001/coverages")
                .header(HttpHeaders.AUTHORIZATION, AUTH))
                .andExpect(status().isOk())
                .andExpect(content().contentType(MediaType.APPLICATION_JSON_UTF8))
                .andExpect(jsonPath("$", hasSize(2)))
                .andExpect(jsonPath("$[0].coverageType", is("DWEL")))
                .andExpect(jsonPath("$[1].coverageType", is("PERS")));
    }

    @Test
    public void getCoverages_policyNotFound() throws Exception {
        mockMvc.perform(get("/api/v1/policies/NONEXISTENT/coverages")
                .header(HttpHeaders.AUTHORIZATION, AUTH))
                .andExpect(status().isNotFound());
    }

    @Test
    public void healthCheck_returnsUp() throws Exception {
        mockMvc.perform(get("/manage/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status", is("UP")));
    }

    @Test
    public void getPolicy_withoutCredentials_unauthorized() throws Exception {
        mockMvc.perform(get("/api/v1/policies/POL-00000001"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    public void getCoverages_withoutCredentials_unauthorized() throws Exception {
        mockMvc.perform(get("/api/v1/policies/POL-00000001/coverages"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    public void getPolicy_wrongPassword_unauthorized() throws Exception {
        mockMvc.perform(get("/api/v1/policies/POL-00000001")
                .header(HttpHeaders.AUTHORIZATION, basic("test-client", "wrong")))
                .andExpect(status().isUnauthorized());
    }

    @Test
    public void healthCheck_anonymous_hidesDetails() throws Exception {
        mockMvc.perform(get("/manage/health"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.db").doesNotExist());
    }

    @Test
    public void sensitiveManagementEndpoints_notExposed() throws Exception {
        String[] paths = {"/manage/heapdump", "/manage/env", "/manage/trace",
                "/manage/dump", "/manage/configprops", "/manage/beans",
                "/manage/mappings", "/manage/metrics", "/manage/autoconfig"};
        for (String path : paths) {
            mockMvc.perform(get(path))
                    .andExpect(status().is(anyOf(is(401), is(404))));
            mockMvc.perform(get(path).header(HttpHeaders.AUTHORIZATION, AUTH))
                    .andExpect(status().is(anyOf(is(403), is(404))));
        }
    }

    @Test
    public void swaggerUi_notExposed() throws Exception {
        mockMvc.perform(get("/swagger-ui.html"))
                .andExpect(status().isUnauthorized());
        mockMvc.perform(get("/v2/api-docs"))
                .andExpect(status().isUnauthorized());
    }
}
