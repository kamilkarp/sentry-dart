import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../sentry_flutter.dart';
import 'screenshot/masking_config.dart';
import 'screenshot/widget_filter.dart';

/// Configuration of the experimental privacy feature.
class SentryPrivacyOptions {
  /// Mask all text content. Draws a rectangle of text bounds with text color
  /// on top. Currently, only [Text] and [EditableText] Widgets are masked.
  /// Default is enabled.
  var maskAllText = true;

  /// Mask content of all images. Draws a rectangle of image bounds with image's
  /// dominant color on top. Currently, only [Image] widgets are masked.
  /// Default is enabled (except for asset images, see [maskAssetImages]).
  var maskAllImages = true;

  /// Redact asset images coming from the root asset bundle.
  var maskAssetImages = false;

  final _userMaskingRules = <SentryMaskingRule>[];

  @internal
  Iterable<SentryMaskingRule> get userMaskingRules => _userMaskingRules;

  @internal
  SentryMaskingConfig buildMaskingConfig(
      SdkLogCallback logger, RuntimeChecker runtimeChecker) {
    // First, we collect rules defined by the user (so they're applied first).
    final rules = _userMaskingRules.toList();

    // Then, we apply rules for [SentryMask] and [SentryUnmask].
    rules.add(const SentryMaskingConstantRule<SentryMask>(
      mask: true,
      name: 'SentryMask',
    ));
    rules.add(const SentryMaskingConstantRule<SentryUnmask>(
      mask: false,
      name: 'SentryUnmask',
    ));

    // Then, we apply apply rules based on the configuration.
    if (maskAllImages) {
      if (maskAssetImages) {
        rules.add(const SentryMaskingConstantRule<Image>(
          mask: true,
          name: 'Image',
        ));
      } else {
        rules.add(const SentryMaskingCustomRule<Image>(
            callback: _maskImagesExceptAssets,
            name: 'Image',
            description: 'Mask all images except asset images.'));
      }
    } else {
      assert(!maskAssetImages,
          "maskAssetImages can't be true if maskAllImages is false");
    }

    if (maskAllText) {
      rules.add(const SentryMaskingConstantRule<Text>(
        mask: true,
        name: 'Text',
      ));
      rules.add(const SentryMaskingConstantRule<EditableText>(
        mask: true,
        name: 'EditableText',
      ));
      rules.add(const SentryMaskingConstantRule<RichText>(
        mask: true,
        name: 'RichText',
      ));
    }

    // In Debug mode, check if users explicitly mask (or unmask) widgets that
    // look like they should be masked, e.g. Videos, WebViews, etc.
    if (runtimeChecker.isDebugMode()) {
      final regexp = RegExp('video|webview|password|pinput|camera|chart',
          caseSensitive: false);

      rules.add(SentryMaskingCustomRule<Widget>(
          callback: (Element element, Widget widget) {
            final type = widget.runtimeType.toString();
            if (regexp.hasMatch(type)) {
              logger(
                  SentryLevel.warning,
                  'Widget "$widget" name matches widgets that should usually be '
                  'masked because they may contain sensitive data. Because this '
                  'widget comes from a third-party plugin or your code, Sentry '
                  "doesn't recognize it and can't reliably mask it in release "
                  'builds (due to obfuscation). '
                  'Please mask it explicitly using options.privacy.mask<$type>(). '
                  'If you want to silence this warning and keep the widget '
                  'visible in captures, you can use options.privacy.unmask<$type>(). '
                  'Note: the RegExp matched is: $regexp (case insensitive).');
            }
            return SentryMaskingDecision.continueProcessing;
          },
          name: 'Widget',
          description:
              'Debug-mode-only warning for potentially sensitive widgets.'));
    }

    return SentryMaskingConfig(rules);
  }

  /// Mask given widget type [T] (or subclasses of [T]) in the replay.
  /// Note: masking rules are called in the order they're added so if a previous
  /// rule already makes a decision, this rule won't be called.
  @experimental
  void mask<T extends Widget>({String? name, String? description}) {
    assert(T != SentryMask);
    assert(T != SentryUnmask);
    _userMaskingRules.add(SentryMaskingConstantRule<T>(
      mask: true,
      name: name ?? T.toString(),
      description: description,
    ));
  }

  /// Unmask given widget type [T] (or subclasses of [T]) in the replay. This is
  /// useful to explicitly show certain widgets that would otherwise be masked
  /// by other rules, for example default [maskAllText] or [maskAllImages].
  /// The [SentryMaskingDecision.unmask] will apply to the widget and its children,
  /// so no other rules will be checked for the children.
  /// Note: masking rules are called in the order they're added so if a previous
  /// rule already makes a decision, this rule won't be called.
  @experimental
  void unmask<T extends Widget>({String? name, String? description}) {
    assert(T != SentryMask);
    assert(T != SentryUnmask);
    _userMaskingRules.add(SentryMaskingConstantRule<T>(
      mask: false,
      name: name ?? T.toString(),
      description: description,
    ));
  }

  /// Provide a custom callback to decide whether to mask the widget of class
  /// [T] (or subclasses of [T]).
  /// Note: masking rules are called in the order they're added so if a previous
  /// rule already makes a decision, this rule won't be called.
  @experimental
  void maskCallback<T extends Widget>(
      SentryMaskingDecision Function(Element, T) shouldMask,
      {String? name,
      String? description}) {
    assert(T != SentryMask);
    assert(T != SentryUnmask);
    _userMaskingRules.add(SentryMaskingCustomRule<T>(
      callback: shouldMask,
      name: name ?? T.toString(),
      description:
          description ?? 'Custom callback-based rule (description unspecified)',
    ));
  }
}

SentryMaskingDecision _maskImagesExceptAssets(Element element, Image widget) {
  final image = widget.image;
  if (image is AssetBundleImageProvider) {
    if (WidgetFilter.isBuiltInAssetImage(image, rootBundle)) {
      return SentryMaskingDecision.continueProcessing;
    }
  }
  return SentryMaskingDecision.mask;
}
