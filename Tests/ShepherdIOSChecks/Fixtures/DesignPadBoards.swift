// The Design tool's fixture boards (iPadDesign, iPadSplitView, DZCanvas): acme's checkout
// funnel, drawn as the Design format's files (`*.dc.html` with the runtime's line and an
// `<x-dc>` template). They render on the simulator with Shepherd's own runtime, as a host's
// boards do on an iPad. Compiled only into the fixture app.
enum DesignPadBoards {
    /// A board file around `body`: its title, the runtime, a helmet declaring acme-web's tokens
    /// (so Tweak snaps to them), the template, and its `$preview` size.
    static func file(title: String, width: Int, height: Int, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <script src="./support.js"></script>
        </head>
        <body>
        <x-dc>
        <helmet>
        <style>
        :root{--accent:#4f46e5;--ink:#0f172a;--muted:#64748b;--surface:#ffffff;--success:#059669;--danger:#dc2626;
        --space-2:8px;--space-3:12px;--space-4:16px;--space-6:24px;--space-8:32px;
        --radius-s:8px;--radius-m:12px;--radius-l:16px;--text-s:12px;--text-m:14px;--text-l:16px;--text-xl:20px}
        body{margin:0}
        </style>
        </helmet>
        \(body)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(width),"height":\(height)}}'>
        class Component extends DCLogic {
          renderVals() {
            return {};
          }
        }
        </script>
        </body>
        </html>
        """
    }

    /// A · Funnel first (1280 × 800).
    static let funnel = file(title: "A · Funnel first", width: 1280, height: 800, body: funnelBody)
    /// A · phone (390 × 844).
    static let phone = file(title: "A · phone", width: 390, height: 844, body: phoneBody)
    /// B · Step table and C · Trend first: A's page under another heading.
    static let steps = file(title: "B · Step table", width: 1280, height: 800,
                            body: funnelBody.replacingOccurrences(of: "Where people drop off between cart and order.",
                                                                  with: "Every step, sortable, with its drop-off."))
    static let trend = file(title: "C · Trend first", width: 1280, height: 800,
                            body: funnelBody.replacingOccurrences(of: "Where people drop off between cart and order.",
                                                                  with: "Conversion over time, then by step."))

    static let funnelBody = #"""
<div style="width: 1280px; height: 800px; background: #f8fafc; font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; color: #0f172a; display: flex; flex-direction: column; overflow: hidden;">
      <div style="height: 60px; display: flex; align-items: center; gap: 28px; padding: 0 32px; background: #ffffff; border-bottom: 1px solid #e2e8f0;">
      <span style="display: flex; align-items: center; gap: 8px; font-size: 16px; font-weight: 700; color: #0f172a;"><span style="width: 22px; height: 22px; border-radius: 6px; background: #4f46e5;"></span>acme</span>
      <span style="display: flex; gap: 24px; margin-left: 16px;"><span style="font-size: 13px; font-weight: 500; color: #64748b; padding: 20px 0; ">Overview</span><span style="font-size: 13px; font-weight: 600; color: #0f172a; padding: 20px 0; box-shadow: inset 0 -2px 0 #4f46e5;">Funnels</span><span style="font-size: 13px; font-weight: 500; color: #64748b; padding: 20px 0; ">Cohorts</span><span style="font-size: 13px; font-weight: 500; color: #64748b; padding: 20px 0; ">Events</span></span>
      <span style="margin-left: auto; display: flex; align-items: center; gap: 12px;"><span style="height: 32px; display: inline-flex; align-items: center; padding: 0 12px; border: 1px solid #e2e8f0; border-radius: 8px; font-size: 13px; color: #0f172a;">Last 30 days</span><span style="width: 30px; height: 30px; border-radius: 50%; background: #cbd5e1;"></span></span>
    </div>
      <div style="flex-grow: 1; display: flex; flex-direction: column; gap: 22px; padding: 30px 32px;"><div style="display: flex; align-items: flex-end; gap: 16px;">
      <div style="display: flex; flex-direction: column; gap: 6px;"><span style="font-size: 26px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">Checkout funnel</span><span style="font-size: 14px; color: #64748b;">Where people drop off between cart and order.</span></div>
      <span style="margin-left: auto; display: flex; gap: 8px;"><span style="height: 30px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; font-size: 12.5px; background: #eef2ff; color: #4f46e5; font-weight: 600;">All platforms</span><span style="height: 30px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; font-size: 12.5px; border: 1px solid #e2e8f0; color: #64748b;">Web</span><span style="height: 30px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; font-size: 12.5px; border: 1px solid #e2e8f0; color: #64748b;">iOS</span><span style="height: 30px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; font-size: 12.5px; border: 1px solid #e2e8f0; color: #64748b;">Android</span></span>
    </div><div data-el="KPI row" style="display: flex; gap: 16px;"><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Sessions with cart</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">48,210</span><span style="font-size: 13px; font-weight: 600; color: #059669;">+4.2%</span></span>
      <span style="font-size: 12px; color: #94a3b8;">vs previous 30 days</span></div><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Reached checkout</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">26.8%</span><span style="font-size: 13px; font-weight: 600; color: #059669;">+1.1pt</span></span>
      <span style="font-size: 12px; color: #94a3b8;">12,904 people</span></div><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Placed order</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">34.0%</span><span style="font-size: 13px; font-weight: 600; color: #dc2626;">−0.8pt</span></span>
      <span style="font-size: 12px; color: #94a3b8;">of checkouts</span></div><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Overall conversion</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">9.1%</span><span style="font-size: 13px; font-weight: 600; color: #059669;">+0.6pt</span></span>
      <span style="font-size: 12px; color: #94a3b8;">cart → order</span></div></div>
        <div style="display: grid; grid-template-columns: 1fr 300px; gap: 16px;">
          <div data-el="Checkout funnel" style="background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px 24px; "><div style="display: flex; align-items: center; margin-bottom: 16px;"><span style="font-size: 15px; font-weight: 600; color: #0f172a;">Checkout funnel</span><span style="margin-left: auto;"><span style="font-size: 12.5px; color: #64748b;">48,210 people</span></span></div><div style="display: grid; grid-template-columns: 170px 1fr 150px; align-items: center; gap: 16px; height: 46px;">
          <span style="font-size: 14px; color: #0f172a;">Cart viewed</span>
          <span style="height: 30px; background: #eef2ff; border-radius: 8px; overflow: hidden;"><span style="display: block; width: 100.0%; height: 100%; background: #4f46e5; border-radius: 8px;"></span></span>
          <span style="display: flex; flex-direction: column; gap: 1px;"><span style="display: flex; gap: 8px; align-items: baseline;"><span style="font-size: 15px; font-weight: 700; color: #0f172a;">100.0%</span><span style="font-size: 12.5px; color: #64748b;">48,210</span></span></span></div><div style="display: grid; grid-template-columns: 170px 1fr 150px; align-items: center; gap: 16px; height: 46px;">
          <span style="font-size: 14px; color: #0f172a;">Checkout started</span>
          <span style="height: 30px; background: #eef2ff; border-radius: 8px; overflow: hidden;"><span style="display: block; width: 26.8%; height: 100%; background: #4f46e5; border-radius: 8px;"></span></span>
          <span style="display: flex; flex-direction: column; gap: 1px;"><span style="display: flex; gap: 8px; align-items: baseline;"><span style="font-size: 15px; font-weight: 700; color: #0f172a;">26.8%</span><span style="font-size: 12.5px; color: #64748b;">12,904</span></span><span style="font-size: 12px; color: #dc2626;">−73% from previous</span></span></div><div style="display: grid; grid-template-columns: 170px 1fr 150px; align-items: center; gap: 16px; height: 46px;">
          <span style="font-size: 14px; color: #0f172a;">Shipping entered</span>
          <span style="height: 30px; background: #eef2ff; border-radius: 8px; overflow: hidden;"><span style="display: block; width: 20.5%; height: 100%; background: #4f46e5; border-radius: 8px;"></span></span>
          <span style="display: flex; flex-direction: column; gap: 1px;"><span style="display: flex; gap: 8px; align-items: baseline;"><span style="font-size: 15px; font-weight: 700; color: #0f172a;">20.5%</span><span style="font-size: 12.5px; color: #64748b;">9,870</span></span><span style="font-size: 12px; color: #dc2626;">−24% from previous</span></span></div><div style="display: grid; grid-template-columns: 170px 1fr 150px; align-items: center; gap: 16px; height: 46px;">
          <span style="font-size: 14px; color: #0f172a;">Payment entered</span>
          <span style="height: 30px; background: #eef2ff; border-radius: 8px; overflow: hidden;"><span style="display: block; width: 13.5%; height: 100%; background: #4f46e5; border-radius: 8px;"></span></span>
          <span style="display: flex; flex-direction: column; gap: 1px;"><span style="display: flex; gap: 8px; align-items: baseline;"><span style="font-size: 15px; font-weight: 700; color: #0f172a;">13.5%</span><span style="font-size: 12.5px; color: #64748b;">6,512</span></span><span style="font-size: 12px; color: #dc2626;">−34% from previous</span></span></div><div style="display: grid; grid-template-columns: 170px 1fr 150px; align-items: center; gap: 16px; height: 46px;">
          <span style="font-size: 14px; color: #0f172a;">Order placed</span>
          <span style="height: 30px; background: #eef2ff; border-radius: 8px; overflow: hidden;"><span style="display: block; width: 9.1%; height: 100%; background: #4f46e5; border-radius: 8px;"></span></span>
          <span style="display: flex; flex-direction: column; gap: 1px;"><span style="display: flex; gap: 8px; align-items: baseline;"><span style="font-size: 15px; font-weight: 700; color: #0f172a;">9.1%</span><span style="font-size: 12.5px; color: #64748b;">4,388</span></span><span style="font-size: 12px; color: #dc2626;">−33% from previous</span></span></div></div>
          <div data-el="Top exit reasons" style="background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px 24px; "><div style="display: flex; align-items: center; margin-bottom: 16px;"><span style="font-size: 15px; font-weight: 600; color: #0f172a;">Top exit reasons</span><span style="margin-left: auto;"><span style="font-size: 12px; color: #64748b;">from exit survey</span></span></div><div style="display: flex; align-items: center; gap: 10px; height: 38px; border-top: none;"><span style="width: 8px; height: 8px; border-radius: 50%; background: #dc2626;"></span><span style="font-size: 13.5px; color: #0f172a;">Shipping cost shown</span><span style="margin-left: auto; font-size: 13.5px; font-weight: 600; color: #0f172a;">31%</span></div><div style="display: flex; align-items: center; gap: 10px; height: 38px; border-top: 1px solid #e2e8f0;"><span style="width: 8px; height: 8px; border-radius: 50%; background: #d97706;"></span><span style="font-size: 13.5px; color: #0f172a;">Account required</span><span style="margin-left: auto; font-size: 13.5px; font-weight: 600; color: #0f172a;">22%</span></div><div style="display: flex; align-items: center; gap: 10px; height: 38px; border-top: 1px solid #e2e8f0;"><span style="width: 8px; height: 8px; border-radius: 50%; background: #d97706;"></span><span style="font-size: 13.5px; color: #0f172a;">Payment failed</span><span style="margin-left: auto; font-size: 13.5px; font-weight: 600; color: #0f172a;">14%</span></div><div style="display: flex; align-items: center; gap: 10px; height: 38px; border-top: 1px solid #e2e8f0;"><span style="width: 8px; height: 8px; border-radius: 50%; background: #94a3b8;"></span><span style="font-size: 13.5px; color: #0f172a;">Promo code field</span><span style="margin-left: auto; font-size: 13.5px; font-weight: 600; color: #0f172a;">9%</span></div><div style="display: flex; align-items: center; gap: 10px; height: 38px; border-top: 1px solid #e2e8f0;"><span style="width: 8px; height: 8px; border-radius: 50%; background: #94a3b8;"></span><span style="font-size: 13.5px; color: #0f172a;">Other</span><span style="margin-left: auto; font-size: 13.5px; font-weight: 600; color: #0f172a;">24%</span></div></div>
        </div></div>
    </div>
"""#

    static let phoneBody = #"""
<div style="width: 390px; height: 844px; background: #f8fafc; font-family: system-ui, -apple-system, 'Segoe UI', sans-serif; color: #0f172a; display: flex; flex-direction: column; overflow: hidden;">
      <div style="height: 54px; display: flex; align-items: center; padding: 0 18px; background: #ffffff; border-bottom: 1px solid #e2e8f0; font-size: 16px; font-weight: 700;"><span style="width: 20px; height: 20px; border-radius: 6px; background: #4f46e5; margin-right: 8px;"></span>acme<span style="margin-left: auto; font-size: 13px; font-weight: 500; color: #64748b;">30 days</span></div>
      <div style="padding: 20px 18px; display: flex; flex-direction: column; gap: 14px;">
        <span style="font-size: 22px; font-weight: 700;">Checkout funnel</span>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;"><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Conversion</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">9.1%</span><span style="font-size: 13px; font-weight: 600; color: #059669;">+0.6pt</span></span>
      <span style="font-size: 12px; color: #94a3b8;"></span></div><div style="flex: 1; display: flex; flex-direction: column; gap: 8px; padding: 18px 20px; background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px;">
      <span style="font-size: 13px; color: #64748b;">Orders</span>
      <span style="display: flex; align-items: baseline; gap: 10px;"><span style="font-size: 28px; font-weight: 700; color: #0f172a; letter-spacing: -0.02em;">4,388</span><span style="font-size: 13px; font-weight: 600; color: #059669;">+6.9%</span></span>
      <span style="font-size: 12px; color: #94a3b8;"></span></div></div>
        <div data-el="Steps list" style="background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 14px 16px; "><div style="display: flex; align-items: center; margin-bottom: 16px;"><span style="font-size: 15px; font-weight: 600; color: #0f172a;">Steps</span><span style="margin-left: auto;"></span></div><div style="display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: none;"><span style="display: flex; font-size: 14px;">Cart viewed<span style="margin-left: auto; font-weight: 700;">100.0%</span></span><span style="height: 10px; border-radius: 5px; background: #eef2ff;"><span style="display: block; height: 100%; width: 100.0%; border-radius: 5px; background: #4f46e5;"></span></span></div><div style="display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: 1px solid #e2e8f0;"><span style="display: flex; font-size: 14px;">Checkout started<span style="margin-left: auto; font-weight: 700;">26.8%</span></span><span style="height: 10px; border-radius: 5px; background: #eef2ff;"><span style="display: block; height: 100%; width: 26.8%; border-radius: 5px; background: #4f46e5;"></span></span></div><div style="display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: 1px solid #e2e8f0;"><span style="display: flex; font-size: 14px;">Shipping entered<span style="margin-left: auto; font-weight: 700;">20.5%</span></span><span style="height: 10px; border-radius: 5px; background: #eef2ff;"><span style="display: block; height: 100%; width: 20.5%; border-radius: 5px; background: #4f46e5;"></span></span></div><div style="display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: 1px solid #e2e8f0;"><span style="display: flex; font-size: 14px;">Payment entered<span style="margin-left: auto; font-weight: 700;">13.5%</span></span><span style="height: 10px; border-radius: 5px; background: #eef2ff;"><span style="display: block; height: 100%; width: 13.5%; border-radius: 5px; background: #4f46e5;"></span></span></div><div style="display: flex; flex-direction: column; gap: 6px; padding: 10px 0; border-top: 1px solid #e2e8f0;"><span style="display: flex; font-size: 14px;">Order placed<span style="margin-left: auto; font-weight: 700;">9.1%</span></span><span style="height: 10px; border-radius: 5px; background: #eef2ff;"><span style="display: block; height: 100%; width: 9.1%; border-radius: 5px; background: #4f46e5;"></span></span></div></div>
      </div></div>
"""#
}
