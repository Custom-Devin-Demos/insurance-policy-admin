package com.acme.insurance.pas.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.annotation.web.configuration.WebSecurityConfigurerAdapter;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.crypto.password.Pbkdf2PasswordEncoder;
import org.springframework.security.provisioning.InMemoryUserDetailsManager;
import org.springframework.util.StringUtils;

/**
 * Service-to-service authentication for the PAS facade.
 *
 * Callers authenticate with HTTP Basic using the API client credentials
 * supplied via PAS_API_CLIENT_ID / PAS_API_CLIENT_SECRET. Only
 * GET /manage/health is anonymous; every other path is denied unless
 * explicitly allowed below. Startup fails if no client secret is set.
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig extends WebSecurityConfigurerAdapter {

    static final String API_CLIENT_ROLE = "PAS_API_CLIENT";

    @Value("${pas.security.api-client.username:}")
    private String apiClientUsername;

    @Value("${pas.security.api-client.password:}")
    private String apiClientPassword;

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new Pbkdf2PasswordEncoder();
    }

    @Bean
    public UserDetailsService userDetailsService(PasswordEncoder passwordEncoder) {
        if (!StringUtils.hasText(apiClientUsername)
                || !StringUtils.hasText(apiClientPassword)) {
            throw new IllegalStateException(
                    "PAS API client credentials are not configured; set "
                            + "PAS_API_CLIENT_ID and PAS_API_CLIENT_SECRET");
        }
        InMemoryUserDetailsManager manager = new InMemoryUserDetailsManager();
        manager.createUser(User.withUsername(apiClientUsername)
                .password(passwordEncoder.encode(apiClientPassword))
                .roles(API_CLIENT_ROLE)
                .build());
        return manager;
    }

    @Override
    protected void configure(HttpSecurity http) throws Exception {
        http
            .csrf().disable()
            .sessionManagement()
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS)
                .and()
            .authorizeRequests()
                .antMatchers(HttpMethod.GET, "/manage/health").permitAll()
                .antMatchers(HttpMethod.GET, "/api/**").hasRole(API_CLIENT_ROLE)
                .anyRequest().denyAll()
                .and()
            .httpBasic();
    }
}
