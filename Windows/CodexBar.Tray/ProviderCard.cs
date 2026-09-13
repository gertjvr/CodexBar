using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace CodexBar.Tray;

// The whole provider summary is a submenu target, as in the macOS menu.
internal sealed class ProviderCard : UserControl
{
    private readonly Border panel;
    private readonly List<(TextBlock Text, Brush Brush)> labels = [];
    private readonly List<(Border Fill, Brush Brush)> fills = [];
    private bool pointerOver, submenuOpen;

    public ProviderCard(StackPanel content, string name)
    {
        panel = new Border { Child = content, Padding = new(6, 8, 6, 8), CornerRadius = new(8), Background = Theme.Brush("00000000") };
        Content = panel;
        Margin = new(-6, -8, -6, 0);
        HorizontalAlignment = HorizontalAlignment.Stretch;
        IsTabStop = true;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, name + " usage details");
        Loaded += (_, _) => Capture(content);
        PointerEntered += (_, _) => { pointerOver = true; Highlight(); };
        PointerExited += (_, _) => { pointerOver = false; Highlight(); };
        GotFocus += (_, _) => Highlight();
        LostFocus += (_, _) => Highlight();
    }

    public void SetSubmenuOpen(bool value) { submenuOpen = value; Highlight(); }

    private void Capture(DependencyObject node)
    {
        if (node is TextBlock text && !labels.Any(item => item.Text == text)) labels.Add((text, text.Foreground));
        if (node is Border fill && Equals(fill.Tag, "UsageFill") && !fills.Any(item => item.Fill == fill)) fills.Add((fill, fill.Background));
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) Capture(VisualTreeHelper.GetChild(node, i));
    }

    private void Highlight()
    {
        var selected = pointerOver || submenuOpen || FocusState == FocusState.Keyboard;
        panel.Background = selected ? Theme.Brush("0759CA") : Theme.Brush("00000000");
        foreach (var (text, brush) in labels) text.Foreground = selected ? Theme.Brush("FFFFFF") : brush;
        foreach (var (fill, brush) in fills) fill.Background = selected ? Theme.Brush("FFFFFF") : brush;
    }
}
