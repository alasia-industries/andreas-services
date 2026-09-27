# The MARKETING distribution — www.humbugg.com, plus the apex which permanently
# redirects to it. The authenticated product moved to its own
# distribution in modules/hosting_app (app.humbugg.com), and the API moved to its own
# custom domain in modules/api_domain (api.humbugg.com), so the /api/*, /health and
# /avatars/* behaviours that used to live here are gone.
#
# The resource is still addressed `aws_cloudfront_distribution.app` rather than
# `.marketing`: renaming it would destroy and recreate the distribution serving
# humbugg.com for no behavioural gain.
#
# The viewer certificate is supplied by modules/certificates, which owns the single
# us-east-1 certificate shared with the API Gateway custom domain.
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_origin_request_policy" "ssr" {
  name    = "${var.project}-${var.environment}-ssr"
  comment = "Forward viewer data to the SSR origin except headers reserved for origin routing"

  headers_config {
    header_behavior = "allExcept"
    headers {
      items = ["host", "authorization"]
    }
  }

  cookies_config {
    cookie_behavior = "all"
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_cloudfront_origin_access_control" "marketing" {
  name                              = "${var.project}-${var.environment}-marketing-oac"
  description                       = "OAC for ${var.project} marketing asset bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "canonical_redirect" {
  name    = "${var.project}-${var.environment}-canonical-redirect"
  runtime = "cloudfront-js-2.0"
  comment = "Redirect non-canonical Humbugg hostnames to ${var.domain_name}"
  publish = true
  code    = file("${path.module}/canonical_redirect.js")
}

locals {
  # Everything in humbugg/marketing/public/ outside /assets — keep in step with that folder.
  public_file_paths = [
    "/favicon.ico",
    "/favicon-*.png",
    "/apple-touch-icon.png",
    "/android-chrome-*.png",
    "/humbugg-favicon.png",
    "/site.webmanifest",
    "/brand/*",
  ]
}

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.project} application distribution"
  price_class     = "PriceClass_100"
  aliases         = [var.domain_name, "www.${var.domain_name}"]

  origin {
    domain_name              = var.marketing_bucket_regional_domain_name
    origin_id                = "S3-marketing"
    origin_access_control_id = aws_cloudfront_origin_access_control.marketing.id
  }

  origin {
    domain_name = var.marketing_api_domain
    origin_id   = "SSR-marketing"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "SSR-marketing"
    viewer_protocol_policy   = "redirect-to-https"
    compress                 = true
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.ssr.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.canonical_redirect.arn
    }
  }

  # The un-hashed files `marketing/public/` puts at the site root (favicons, the web
  # manifest, the brand art). The deploy uploads them to the bucket with the hashed
  # assets, but without a behavior of their own they fell to the SSR default and
  # 404'd there — `/favicon.ico` included. Explicit paths, not `/*.png`, so a future
  # page route can never be shadowed by the bucket.
  dynamic "ordered_cache_behavior" {
    for_each = local.public_file_paths
    content {
      path_pattern           = ordered_cache_behavior.value
      allowed_methods        = ["GET", "HEAD"]
      cached_methods         = ["GET", "HEAD"]
      target_origin_id       = "S3-marketing"
      viewer_protocol_policy = "redirect-to-https"
      compress               = true
      cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

      function_association {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.canonical_redirect.arn
      }
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/assets/*"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-marketing"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.canonical_redirect.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = var.tags
}

resource "aws_s3_bucket_policy" "marketing" {
  bucket = var.marketing_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${var.marketing_bucket_arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.app.arn
          }
        }
      }
    ]
  })
}

resource "aws_route53_record" "canonical" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.route53_zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.route53_zone_id
  name    = "www.${var.domain_name}"
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.app.domain_name
    zone_id                = aws_cloudfront_distribution.app.hosted_zone_id
    evaluate_target_health = false
  }
}
