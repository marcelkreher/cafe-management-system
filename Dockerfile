FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Cafe.slnx .
COPY src/Cafe.Api/Cafe.Api.csproj src/Cafe.Api/
COPY src/Cafe.SharedKernel/Cafe.SharedKernel.csproj src/Cafe.SharedKernel/
COPY src/Cafe.Modules.Reservation/Cafe.Modules.Reservation.csproj src/Cafe.Modules.Reservation/
COPY src/Cafe.Modules.IdentityAccess/Cafe.Modules.IdentityAccess.csproj src/Cafe.Modules.IdentityAccess/
COPY src/Cafe.Modules.Notification/Cafe.Modules.Notification.csproj src/Cafe.Modules.Notification/
RUN dotnet restore src/Cafe.Api/Cafe.Api.csproj

COPY src/ src/
RUN dotnet publish src/Cafe.Api/Cafe.Api.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app .

ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Cafe.Api.dll"]
